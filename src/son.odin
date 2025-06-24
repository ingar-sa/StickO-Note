package son

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import str "core:strings"

import b2 "vendor:box2d"
import rl "vendor:raylib"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
FPS :: 60
MONITOR :: 0

NOTE_TEXT_OFFSET :: 5
RESET_CLICKED_FRAME_COUNT :: FPS * 0.5
NOTE_MIN_DIM :: [2]f32{256, 256}
CORNER_CHECK_DIMS :: [2]f32{30, 30}

NoteColors := []rl.Color {
    rl.LIGHTGRAY,
    rl.YELLOW,
    rl.PINK,
    rl.VIOLET,
    rl.MAROON,
    rl.BEIGE,
    rl.MAGENTA,
}

corner :: enum 
{
    TL,
    TR,
    BL,
    BR,
}

note_mode :: enum 
{
    Idle,
    Moving,
    Resizing,
    Typing,
}

/*
 * Pinned state where it won't resize or move
*/
note :: struct 
{
    Rec:       rl.Rectangle,
    RecColor:  rl.Color,
    FontColor: rl.Color,
    FontSize:  f32,
    Text:      str.Builder, // TODO: (isa): Store separately to make search and stuff easier?
}

/*
 * Undo note movement and resizing
 */
canvas :: struct 
{
    Name:           string,
    FontFilename:   string,
    Font:           rl.Font,
    HotNoteIdx:     int,
    HotNote:        ^note,
    ActiveNoteIdx:  int,
    ActiveNote:     ^note,
    ActiveNoteMode: note_mode,
    ResizingCorner: corner,
    Notes:          [dynamic]note,
}

mouse_button_state :: struct 
{
    Down:          bool,
    Up:            bool,
    Pressed:       bool,
    Released:      bool,
    Clicked:       bool,
    DoubleClicked: bool,
    FrameClicked:  uint,
}

mouse_state :: struct 
{
    L: mouse_button_state,
    R: mouse_button_state,
}

keyboard_key :: enum 
{
    Unknown,
    Left_Control,
    Left_Shift,
    Enter,
    Escape,
    Backspace,
}

key_state :: struct 
{
    Pressed:       bool,
    PressedRepeat: bool,
    Down:          bool,
    Up:            bool,
}

keyboard_state :: struct 
{
    KeyPressed:  rl.KeyboardKey,
    CharPressed: rune,
    Keys:        [keyboard_key]key_state,
}

son_state :: struct 
{
    Initialized: bool,
    FrameCount:  uint,
    Canvas:      ^canvas,
    Mouse:       mouse_state,
    Keyboard:    keyboard_state,
}

Son: son_state

NewNote :: proc(
    Rec := rl.Rectangle{},
    RecColor := rl.YELLOW,
    FontColor := rl.BLACK,
    FontSize := f32(18),
    Allocator := context.allocator,
) -> note 
{
    Note := note{Rec, RecColor, FontColor, FontSize, {}}
    str.builder_init_none(&Note.Text, Allocator)
    return Note
}

NewCanvas :: proc(Name: string, FontFilename: string, Allocator := context.allocator) -> ^canvas 
{
    Font := rl.LoadFont(str.clone_to_cstring(FontFilename, context.temp_allocator))
    if Font == {} 
    {
        Font = rl.GetFontDefault()
    }

    Canvas := new(canvas, Allocator)
    Canvas.Name = str.clone(Name, Allocator)
    Canvas.FontFilename = str.clone(FontFilename, Allocator)
    Canvas.Font = Font
    Canvas.HotNoteIdx = -1
    Canvas.ActiveNoteIdx = -1
    Canvas.Notes = make([dynamic]note, Allocator)
    return Canvas
}

DeleteCanvas :: proc(Canvas: ^canvas) 
{
    delete(Canvas.Name)
    delete(Canvas.FontFilename)
    rl.UnloadFont(Canvas.Font)
    delete(Canvas.Notes)
    free(Canvas)
}

UpdateMouseButtonClicked :: proc(Button: ^mouse_button_state) 
{
    Button.DoubleClicked = Button.DoubleClicked || (Button.Clicked && Button.Pressed)
    Button.Clicked = Button.Clicked || (!Button.Clicked && Button.Pressed)
    Button.FrameClicked =
        Button.FrameClicked == 0 && Button.Clicked ? Son.FrameCount : Button.FrameClicked
}

ResetMouseButtonClicked :: proc(Button: ^mouse_button_state) 
{
    Button.Clicked = false
    Button.DoubleClicked = false
    Button.FrameClicked = 0
}

GetRlMouseButtonState :: proc(ButtonState: ^mouse_button_state, Button: rl.MouseButton) 
{
    ButtonState.Down = rl.IsMouseButtonDown(Button)
    ButtonState.Up = rl.IsMouseButtonReleased(Button)
    ButtonState.Pressed = rl.IsMouseButtonPressed(Button)
    ButtonState.Released = rl.IsMouseButtonReleased(Button)
}

GetRlKeyboardKeyState :: proc(State: ^key_state, Key: rl.KeyboardKey) 
{
    State.Pressed = rl.IsKeyPressed(Key)
    State.PressedRepeat = rl.IsKeyPressedRepeat(Key)
    State.Down = rl.IsKeyDown(Key)
    State.Up = rl.IsKeyUp(Key)
}

UnsetActiveNote :: proc(Canvas: ^canvas) 
{
    Canvas.ActiveNoteIdx = -1
    Canvas.ActiveNote = nil
    Canvas.ActiveNoteMode = .Idle
}

SetActiveNote :: proc(Canvas: ^canvas, Idx: int) 
{
    LastIdx := len(Canvas.Notes) - 1
    TopNote := Canvas.Notes[LastIdx]
    NewActiveNote := Canvas.HotNote

    Canvas.Notes[LastIdx] = NewActiveNote^
    Canvas.Notes[Canvas.HotNoteIdx] = TopNote

    Canvas.HotNoteIdx = LastIdx
    Canvas.ActiveNoteIdx = LastIdx
    Canvas.ActiveNote = &Canvas.Notes[Canvas.ActiveNoteIdx]
}

SetHotNote :: proc(Canvas: ^canvas, Idx: int) 
{
    Canvas.HotNoteIdx = Idx
    Canvas.HotNote = &Canvas.Notes[Idx]
}

UnsetHotNote :: proc(Canvas: ^canvas) 
{
    Canvas.HotNoteIdx = -1
    Canvas.HotNote = nil
}

AddNote :: proc(
    Canvas: ^canvas,
    Pos: rl.Vector2,
    Color := rl.YELLOW,
    FontColor := rl.BLACK,
    FontSize := f32(18),
    Text := "",
    Allocator := context.allocator,
) 
{
    Rec := rl.Rectangle{Pos.x - NOTE_MIN_DIM.x / 2, Pos.y - 10, NOTE_MIN_DIM.x, NOTE_MIN_DIM.y}
    Note := note{Rec, Color, FontColor, FontSize, {}}
    str.builder_init(&Note.Text, Allocator)
    str.write_string(&Note.Text, Text)
    append(&Canvas.Notes, Note)
}

ResizedRecFromCorner :: proc(Rec: rl.Rectangle, Corner: corner, Delta: rl.Vector2) -> rl.Rectangle 
{
    Rec := Rec
    switch Corner 
    {
    case .TL:
        Rec.x += Rec.width + -Delta.x < NOTE_MIN_DIM.x ? Rec.width - NOTE_MIN_DIM.x : Delta.x
        Rec.y += Rec.height + -Delta.y < NOTE_MIN_DIM.y ? Rec.height - NOTE_MIN_DIM.y : Delta.y
        Rec.height = max(Rec.height + -Delta.y, NOTE_MIN_DIM.y)
        Rec.width = max(Rec.width + -Delta.x, NOTE_MIN_DIM.x)
    case .TR:
        Rec.y += Rec.height + -Delta.y < NOTE_MIN_DIM.y ? Rec.height - NOTE_MIN_DIM.y : Delta.y
        Rec.height = max(Rec.height + -Delta.y, NOTE_MIN_DIM.y)
        Rec.width = max(Rec.width + Delta.x, NOTE_MIN_DIM.x)
    case .BL:
        Rec.x += Rec.width + -Delta.x < NOTE_MIN_DIM.x ? Rec.width - NOTE_MIN_DIM.x : Delta.x
        Rec.height = max(Rec.height + Delta.y, NOTE_MIN_DIM.y)
        Rec.width = max(Rec.width + -Delta.x, NOTE_MIN_DIM.x)
    case .BR:
        Rec.width = max(Rec.width + Delta.x, NOTE_MIN_DIM.x)
        Rec.height = max(Rec.height + Delta.y, NOTE_MIN_DIM.y)
    }

    return Rec
}

SetNoteText :: proc(Note: ^note, Text: string) 
{
    str.builder_reset(&Note.Text)
    str.write_string(&Note.Text, Text)
}

AddRuneToText :: proc(Text: ^str.Builder, Rune: rune) 
{
    if Rune != 0 
    {
        str.write_rune(Text, Rune)
    }
}

BackspaceText :: proc(Text: ^str.Builder, Count: int) 
{
    for _ in 0 ..< Count 
    {
        str.pop_rune(Text)
    }
}

DrawNoteOutline :: proc(Note: note) 
{
    OutlineWidth := f32(8) + Note.Rec.width / 110 + Note.Rec.height / 110
    Outline := rl.Rectangle {
        Note.Rec.x - OutlineWidth,
        Note.Rec.y - OutlineWidth,
        Note.Rec.width + 2 * OutlineWidth,
        Note.Rec.height + 2 * OutlineWidth,
    }
    OutlineColor := Note.RecColor
    OutlineColor.a = 100
    rl.DrawRectangleLinesEx(Outline, OutlineWidth, OutlineColor)
}

DrawCornerLines :: proc(Note: note, Corner: corner, MousePos: rl.Vector2) 
{
    Rec := Note.Rec
    switch Corner 
    {
    case .TL:
        StartH := rl.Vector2{Rec.x + 2, Rec.y + 4}
        StartV := rl.Vector2{Rec.x + 4, Rec.y + 2}
        rl.DrawLineEx(StartH, {StartH.x + 20, StartH.y}, 4, rl.BLACK)
        rl.DrawLineEx(StartV, {StartV.x, StartV.y + 20}, 4, rl.BLACK)
    case .TR:
        StartH := rl.Vector2{Rec.x + Rec.width - 2, Rec.y + 4}
        StartV := rl.Vector2{Rec.x + Rec.width - 4, Rec.y + 2}
        rl.DrawLineEx(StartH, {StartH.x - 20, StartH.y}, 4, rl.BLACK)
        rl.DrawLineEx(StartV, {StartV.x, StartV.y + 20}, 4, rl.BLACK)
    case .BL:
        StartH := rl.Vector2{Rec.x + 2, Rec.y + Rec.height - 4}
        StartV := rl.Vector2{Rec.x + 4, Rec.y + Rec.height - 2}
        rl.DrawLineEx(StartH, {StartH.x + 20, StartH.y}, 4, rl.BLACK)
        rl.DrawLineEx(StartV, {StartV.x, StartV.y - 20}, 4, rl.BLACK)
    case .BR:
        StartH := rl.Vector2{Rec.x + Rec.width - 2, Rec.y + Rec.height - 4}
        StartV := rl.Vector2{Rec.x + Rec.width - 4, Rec.y + Rec.height - 2}
        rl.DrawLineEx(StartH, {StartH.x - 20, StartH.y}, 4, rl.BLACK)
        rl.DrawLineEx(StartV, {StartV.x, StartV.y - 20}, 4, rl.BLACK)
    }
}

CollisionPointRecCorner :: proc(
    Point: [2]f32,
    Rec: rl.Rectangle,
    CornerDims: [2]f32,
) -> Maybe(corner) 
{
    TLRec := rl.Rectangle{Rec.x, Rec.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, TLRec) 
    {
        return .TL
    }

    TRRec := rl.Rectangle{Rec.x + Rec.width - CornerDims.x, Rec.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, TRRec) 
    {
        return .TR
    }

    BLRec := rl.Rectangle{Rec.x, Rec.y + Rec.height - CornerDims.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, BLRec) 
    {
        return .BL
    }

    BRRec := rl.Rectangle {
        Rec.x + Rec.width - CornerDims.x,
        Rec.y + Rec.height - CornerDims.y,
        CornerDims.x,
        CornerDims.y,
    }
    if rl.CheckCollisionPointRec(Point, BRRec) 
    {
        return .BR
    }

    return nil
}

RlRecAdd :: proc(Rec1: rl.Rectangle, Addend: [4]f32) -> rl.Rectangle 
{
    NewRec := rl.Rectangle {
        Rec1.x + Addend[0],
        Rec1.y + Addend[1],
        Rec1.width + Addend[2],
        Rec1.height + Addend[3],
    }
    return NewRec
}

IncrementOffsetsByTypeVal :: proc(From, To: ^int, $F: typeid, TInc: int) 
{
    From^ += size_of(F)
    To^ += TInc
}

IncrementOffsetsByValType :: proc(From, To: ^int, FInc: int, $T: typeid) 
{
    From^ += FInc
    To^ += size_of(T)
}

IncrementOffsetsByType :: proc(From, To: ^int, $F: typeid, $T: typeid) 
{
    From^ += size_of(F)
    To^ += size_of(T)
}

IncrementOffsetsByVal :: proc(From, To: ^int, FInc, TInc: int) 
{
    From^ += FInc
    To^ += TInc
}

IncrementOffsets :: proc 
{
    IncrementOffsetsByTypeVal,
    IncrementOffsetsByValType,
    IncrementOffsetsByVal,
    IncrementOffsetsByType,
}

SliceToTypeOffset :: proc(Buf: []byte, $T: typeid, Off: ^int) -> T 
{
    Val := slice.to_type(Buf[Off^:], T)
    Off^ += size_of(T)
    return Val
}

SliceToStringOffset :: proc(Buf: []byte, StringLen: int, Off: ^int) -> string 
{
    String := string(Buf[Off^:Off^ + StringLen])
    Off^ += StringLen
    return String
}

DEFAULT_SAVE_DIR :: "saves/"
CANVAS_EXTENSION :: ".soncanv"

SaveCanvas :: proc(
    Canvas: ^canvas,
    DirectoryName := DEFAULT_SAVE_DIR,
    Allocator := context.temp_allocator,
) -> (
    Err: os.Error,
) 
{
    DirectoryExists := os.is_dir_path(DirectoryName)
    if DirectoryName != DEFAULT_SAVE_DIR && !DirectoryExists 
    {
        return os.ENOENT
    }
     else if DirectoryName == DEFAULT_SAVE_DIR && !DirectoryExists 
    {
        os.make_directory(DEFAULT_SAVE_DIR) or_return
    }

    FilenameB: str.Builder
    str.builder_init_none(&FilenameB, Allocator)
    str.write_string(&FilenameB, DirectoryName)
    str.write_string(&FilenameB, Canvas.Name)
    str.write_string(&FilenameB, CANVAS_EXTENSION)

    SavefileName := str.to_string(FilenameB)
    Handle := os.open(
        SavefileName,
        os.O_WRONLY | os.O_CREATE | os.O_TRUNC,
        os.S_IRUSR | os.S_IWUSR,
    ) or_return
    defer os.close(Handle)


    TextSize := len(Canvas.Name)
    os.write_ptr(Handle, &TextSize, size_of(TextSize)) or_return
    os.write_string(Handle, Canvas.Name) or_return

    TextSize = len(Canvas.FontFilename)
    os.write_ptr(Handle, &TextSize, size_of(TextSize)) or_return
    os.write_string(Handle, Canvas.FontFilename) or_return

    NoteCount := len(Canvas.Notes)
    os.write_ptr(Handle, &NoteCount, size_of(NoteCount)) or_return

    for &Note in Canvas.Notes 
    {
        os.write_ptr(Handle, &Note.Rec, size_of(Note.Rec)) or_return
        os.write_ptr(Handle, &Note.RecColor, size_of(Note.RecColor)) or_return
        os.write_ptr(Handle, &Note.FontColor, size_of(Note.FontColor)) or_return
        os.write_ptr(Handle, &Note.FontSize, size_of(Note.FontSize)) or_return

        Text := str.to_string(Note.Text)
        TextSize = len(Text)
        os.write_ptr(Handle, &TextSize, size_of(TextSize)) or_return
        os.write_string(Handle, Text) or_return
    }

    fmt.printfln("Successfully saved canvas \"%v\" to \"%v\"", Canvas.Name, SavefileName)
    return os.ERROR_NONE
}

LoadCanvas :: proc(
    CanvasName: string,
    DirectoryName := DEFAULT_SAVE_DIR,
    CanvasAllocator := context.allocator,
    TempAllocator := context.temp_allocator,
) -> (
    Canvas: ^canvas,
    Err: os.Error,
) 
{
    if !os.is_dir_path(DirectoryName) 
    {
        return {}, os.ENOENT
    }

    FilenameB: str.Builder
    str.builder_init_none(&FilenameB, TempAllocator)
    str.write_string(&FilenameB, DirectoryName)
    str.write_string(&FilenameB, CanvasName)
    str.write_string(&FilenameB, CANVAS_EXTENSION)
    Bytes := os.read_entire_file_from_filename_or_err(
        str.to_string(FilenameB),
        TempAllocator,
    ) or_return

    Off: int
    TextSize := SliceToTypeOffset(Bytes, int, &Off)
    Name := SliceToStringOffset(Bytes, TextSize, &Off)
    TextSize = SliceToTypeOffset(Bytes, int, &Off)
    FontFilename := SliceToStringOffset(Bytes, TextSize, &Off)
    NoteCount := SliceToTypeOffset(Bytes, int, &Off)
    Canvas = NewCanvas(Name, FontFilename, CanvasAllocator)

    for i in 0 ..< NoteCount 
    {
        append(&Canvas.Notes, note{})
        Note := &Canvas.Notes[i]

        Note.Rec = SliceToTypeOffset(Bytes, type_of(Note.Rec), &Off)
        Note.RecColor = SliceToTypeOffset(Bytes, type_of(Note.RecColor), &Off)
        Note.FontColor = SliceToTypeOffset(Bytes, type_of(Note.FontColor), &Off)
        Note.FontSize = SliceToTypeOffset(Bytes, type_of(Note.FontSize), &Off)

        TextSize = SliceToTypeOffset(Bytes, int, &Off)
        Text := SliceToStringOffset(Bytes, TextSize, &Off)

        str.builder_init_none(&Note.Text, CanvasAllocator)
        str.write_string(&Note.Text, Text)
    }

    fmt.printfln(
        "Successfully loaded canvas \"%v\" from \"%v\"",
        Canvas.Name,
        str.to_string(FilenameB),
    )
    return Canvas, os.ERROR_NONE
}


TrackingAllocatorFini :: proc(Track: ^mem.Tracking_Allocator) 
{
    if len(Track.allocation_map) > 0 
    {
        for _, Entry in Track.allocation_map 
        {
            fmt.eprintfln("%v leaked %v bytes\n", Entry.location, Entry.size)
        }
    }

    mem.tracking_allocator_destroy(Track)
}


main :: proc() 
{
    Track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&Track, context.allocator)
    context.allocator = mem.tracking_allocator(&Track)
    defer TrackingAllocatorFini(&Track)

    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "StickO-Note")
    rl.SetTargetFPS(FPS)
    rl.SetWindowMonitor(MONITOR)
    WindowConfig := rl.ConfigFlags{.WINDOW_RESIZABLE}
    rl.SetWindowState(WindowConfig)
    rl.SetExitKey(.END)
    defer rl.CloseWindow()

    Camera := rl.Camera2D{}
    Camera.target = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
    Camera.offset = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
    Camera.zoom = 1

    FontColor := rl.BLACK
    Canvas, LoadErr := LoadCanvas("Testing")
    if LoadErr != os.ERROR_NONE 
    {
        if LoadErr == os.ENOENT 
        {
            Canvas = NewCanvas("Testing", "/home/ingarsa/.local/share/fonts/d/DroidSansMNFM.ttf")
            AddNote(Canvas, {256, 128}, Text = "Hellope!")
            AddNote(
                Canvas,
                {768, 128},
                Text = "Failed to load canvas Testing from file!\nIt did not exist",
            )
        }
         else 
        {
            fmt.eprintfln("Failed to load canvas Testing (error %v)", LoadErr)
        }
    }

    Son.Canvas = Canvas
    Mouse := &Son.Mouse
    Keyboard := &Son.Keyboard
    Keys := &Keyboard.Keys
    for !rl.WindowShouldClose() 
    {
        rl.BeginDrawing()
        rl.BeginMode2D(Camera)
        rl.ClearBackground(rl.DARKGRAY)

        WindowWidth := rl.GetScreenWidth()
        WindowHeight := rl.GetScreenHeight()
        CurrentScreenWorldPos := rl.GetScreenToWorld2D(Camera.target, Camera)

        MouseScreenPos := rl.GetMousePosition()
        MouseWorldPos := rl.GetScreenToWorld2D(MouseScreenPos, Camera)
        MouseDelta := rl.GetMouseDelta()
        ScaledMDelta := MouseDelta / Camera.zoom

        GetRlMouseButtonState(&Mouse.L, .LEFT)
        GetRlMouseButtonState(&Mouse.R, .RIGHT)
        if Mouse.L.FrameClicked != 0 &&
           (Son.FrameCount - Mouse.L.FrameClicked) >= RESET_CLICKED_FRAME_COUNT 
        {
            ResetMouseButtonClicked(&Mouse.L)
        }

        if Mouse.R.FrameClicked != 0 &&
           (Son.FrameCount - Mouse.R.FrameClicked) >= RESET_CLICKED_FRAME_COUNT 
        {
            ResetMouseButtonClicked(&Mouse.R)
        }

        UpdateMouseButtonClicked(&Mouse.L)
        UpdateMouseButtonClicked(&Mouse.R)

        Camera.zoom += rl.GetMouseWheelMove() * 0.15 * Camera.zoom
        if Camera.zoom <= 0.05 
        {
            Camera.zoom = 0.05
        }

        if Mouse.R.Down 
        {
            Camera.target -= ScaledMDelta
        }

        Keyboard.CharPressed = rl.GetCharPressed()
        Keyboard.KeyPressed = rl.GetKeyPressed()
        GetRlKeyboardKeyState(&Keys[.Left_Control], .LEFT_CONTROL)
        GetRlKeyboardKeyState(&Keys[.Left_Shift], .LEFT_SHIFT)
        GetRlKeyboardKeyState(&Keys[.Enter], .ENTER)
        GetRlKeyboardKeyState(&Keys[.Escape], .ESCAPE)
        GetRlKeyboardKeyState(&Keys[.Backspace], .BACKSPACE)

        if Keyboard.KeyPressed == .ZERO 
        {
            Camera.target = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.offset = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.zoom = 1
        }
         else if Canvas.ActiveNoteMode == .Idle &&
           Keys[.Left_Shift].Down &&
           Keyboard.KeyPressed == .N 
        {
            NoteColor := NoteColors[Son.FrameCount % len(NoteColors)]
            AddNote(Canvas, MouseWorldPos, NoteColor)
            SetNoteText(&Canvas.Notes[len(Canvas.Notes) - 1], "New Note!")
        }
         else if Canvas.ActiveNoteMode == .Idle &&
           Keys[.Left_Control].Down &&
           Keyboard.KeyPressed == .S 
        {
            if SaveErr := SaveCanvas(Son.Canvas); SaveErr != os.ERROR_NONE 
            {
                fmt.eprintfln("Failed to save canvas \"%v\" (error %v)", Son.Canvas.Name, SaveErr)
                return
            }
        }
         else if Canvas.ActiveNoteMode == .Idle &&
           Keys[.Left_Control].Down &&
           Keyboard.KeyPressed == .L 
        {
            if LoadedCanvas, LoadErr := LoadCanvas(Son.Canvas.Name); LoadErr == os.ERROR_NONE 
            {
                DeleteCanvas(Son.Canvas)
                Son.Canvas = LoadedCanvas
                Canvas = LoadedCanvas
            }
             else 
            {
                fmt.eprintfln("Failed to load canvas \"%v\" (error %v)", Son.Canvas.Name, LoadErr)
                return
            }
        }

        UnsetHotNote(Canvas)
        MouseOverCorner: bool
        CornerMouseOver: corner
        #reverse for &Note, i in Canvas.Notes 
        {
            MouseOverNote := rl.CheckCollisionPointRec(MouseWorldPos, Note.Rec)
            if MouseOverNote 
            {
                SetHotNote(Canvas, i)
                CornerMouseOver, MouseOverCorner =
                CollisionPointRecCorner(MouseWorldPos, Note.Rec, CORNER_CHECK_DIMS).?
                break
            }
        }

        OldActiveNote: note // NOTE: (isa): Used to make trailing outline
        if Canvas.ActiveNoteIdx >= 0 
        {
            OldActiveNote = Canvas.Notes[Canvas.ActiveNoteIdx]
            ActiveNote := Canvas.ActiveNote
            ActiveNoteMode := Canvas.ActiveNoteMode
            Rec := &Canvas.ActiveNote.Rec

            switch ActiveNoteMode 
            {
            case .Typing:
                // TODO: (isa): 
                //              Ctrl+[Z, Backspace]
                //              Wrapping text
                //              Single backspace
                //              Cursor
                //              Moving cursor in text
                ExitedTyping := Mouse.L.Pressed && Canvas.HotNoteIdx < 0 || Keys[.Escape].Pressed
                if ExitedTyping 
                {
                    UnsetActiveNote(Canvas)
                    break
                }

                // TODO: (isa): Having this framerate dependent is probably not a good idea lol
                if Keys[.Backspace].Pressed || Keys[.Backspace].Down && Son.FrameCount % 3 == 0 
                {
                    BackspaceText(&ActiveNote.Text, 1)
                }
                 else 
                {
                    Rune := Keyboard.CharPressed
                    Rune = Keys[.Enter].Pressed ? '\n' : Rune
                    AddRuneToText(&ActiveNote.Text, Rune)
                }

            case .Moving:
                if Mouse.L.Released 
                {
                    UnsetActiveNote(Canvas)
                    break
                }

                Rec.x += ScaledMDelta.x
                Rec.y += ScaledMDelta.y

            case .Resizing:
                if Mouse.L.Released 
                {
                    UnsetActiveNote(Canvas)
                    break
                }

                Rec^ = ResizedRecFromCorner(Rec^, Canvas.ResizingCorner, ScaledMDelta)

            case .Idle:
            }
        }
         else if Canvas.HotNoteIdx >= 0 
        {
            // TODO: (isa): Bug when you double click on note!
            if Mouse.L.DoubleClicked 
            {
                SetActiveNote(Canvas, Canvas.HotNoteIdx)
                Canvas.ActiveNoteMode = .Typing
                ResetMouseButtonClicked(&Mouse.L)
            }
             else if Mouse.L.Down 
            {
                SetActiveNote(Canvas, Canvas.HotNoteIdx)
                OldActiveNote = Canvas.Notes[Canvas.ActiveNoteIdx]

                if MouseOverCorner 
                {
                    Canvas.ActiveNoteMode = .Resizing
                    Canvas.ResizingCorner = CornerMouseOver
                }
                 else 
                {
                    Canvas.ActiveNoteMode = .Moving
                }
            }
             else if Keyboard.KeyPressed == .D && Keys[.Left_Shift].Down 
            {
                unordered_remove(&Canvas.Notes, Canvas.HotNoteIdx)
                UnsetHotNote(Canvas)
            }
        }

        for &Note, i in Canvas.Notes 
        {
            rl.DrawRectangleRec(Note.Rec, Note.RecColor)
            if Text, AllocOk := str.to_cstring(&Note.Text); AllocOk == .None 
            {
                Pos := rl.Vector2{Note.Rec.x + NOTE_TEXT_OFFSET, Note.Rec.y + NOTE_TEXT_OFFSET}
                rl.DrawTextPro(Canvas.Font, Text, Pos, {}, 0, Note.FontSize, 0, Note.FontColor)
            }

            if i == Canvas.ActiveNoteIdx 
            {
                DrawNoteOutline(OldActiveNote)
                if Canvas.ActiveNoteMode == .Resizing 
                {
                    DrawCornerLines(Note, Canvas.ResizingCorner, MouseWorldPos)
                }
                 else if Canvas.ActiveNoteMode == .Typing 
                {
                    RecOffset := f32(NOTE_TEXT_OFFSET - 2)
                    TextRec := RlRecAdd(
                        Note.Rec,
                        {RecOffset, RecOffset, -2 * RecOffset, -2 * RecOffset},
                    )
                    rl.DrawRectangleLinesEx(TextRec, 1, rl.BLACK)
                }
            }
             else if i == Canvas.HotNoteIdx 
            {
                DrawNoteOutline(Note)
                if MouseOverCorner 
                {
                    DrawCornerLines(Note, CornerMouseOver, MouseWorldPos)
                }
            }
        }

        rl.EndMode2D()
        rl.EndDrawing()
        free_all(context.temp_allocator)
        Son.FrameCount += 1
    }
}
