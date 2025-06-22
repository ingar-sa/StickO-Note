package son

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
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

note :: struct 
{
    Rec:       rl.Rectangle,
    RecColor:  rl.Color,
    FontColor: rl.Color,
    FontSize:  f32,
    Text:      str.Builder, // TODO: (isa): Store separately to make search and stuff easier?
}

canvas :: struct 
{
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
    Canvas:      canvas,
    Mouse:       mouse_state,
    Keyboard:    keyboard_state,
}

Son: son_state


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

UnsetActiveNoteIfTrue :: proc(Canvas: ^canvas, Condition: bool) 
{
    if Condition 
    {
        Canvas.ActiveNoteIdx = -1
        Canvas.ActiveNote = nil
        Canvas.ActiveNoteMode = .Idle
    }
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
    Allocator := context.allocator,
) 
{
    Rec := rl.Rectangle{Pos.x - NOTE_MIN_DIM.x / 2, Pos.y - 10, NOTE_MIN_DIM.x, NOTE_MIN_DIM.y}
    Note := note{Rec, Color, FontColor, FontSize, {}}
    str.builder_init(&Note.Text, Allocator)
    append(&Canvas.Notes, Note)
}

ResizeRecFromCorner :: proc(Rec: ^rl.Rectangle, Corner: corner, Delta: rl.Vector2) 
{
    NewX := Rec.x
    NewY := Rec.y
    NewWidth := Rec.width
    NewHeight := Rec.height

    switch Corner 
    {
    case .TL:
        if NewWidth + -Delta.x < NOTE_MIN_DIM.x 
        {
            NewX += NewWidth - NOTE_MIN_DIM.x
        }
         else 
        {
            NewX += Delta.x
        }
        if NewHeight + -Delta.y < NOTE_MIN_DIM.y 
        {
            NewY += NewHeight - NOTE_MIN_DIM.y
        }
         else 
        {
            NewY += Delta.y
        }
        NewHeight = max(NewHeight + -Delta.y, NOTE_MIN_DIM.y)
        NewWidth = max(NewWidth + -Delta.x, NOTE_MIN_DIM.x)
    case .TR:
        if NewHeight + -Delta.y < NOTE_MIN_DIM.y 
        {
            NewY += NewHeight - NOTE_MIN_DIM.y
        }
         else 
        {
            NewY += Delta.y
        }
        NewHeight = max(NewHeight + -Delta.y, NOTE_MIN_DIM.y)
        NewWidth = max(NewWidth + Delta.x, NOTE_MIN_DIM.x)
    case .BL:
        if NewWidth + -Delta.x < NOTE_MIN_DIM.x 
        {
            NewX += NewWidth - NOTE_MIN_DIM.x
        }
         else 
        {
            NewX += Delta.x
        }
        NewHeight = max(NewHeight + Delta.y, NOTE_MIN_DIM.y)
        NewWidth = max(NewWidth + -Delta.x, NOTE_MIN_DIM.x)
    case .BR:
        NewWidth = max(Rec.width + Delta.x, NOTE_MIN_DIM.x)
        NewHeight = max(Rec.height + Delta.y, NOTE_MIN_DIM.y)
    }

    Rec^ = {NewX, NewY, NewWidth, NewHeight}
}

SetNoteText :: proc(Note: ^note, Text: string) 
{
    str.builder_reset(&Note.Text)
    str.write_string(&Note.Text, Text)
    fmt.println("New string:", str.to_string(Note.Text))
}

AddRuneToText :: proc(Text: ^str.Builder, Rune: rune) 
{
    if Rune != 0 
    {
        fmt.printfln("Writing rune %v to text", Rune)
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

SaveCanvas :: proc(Canvas: canvas, Filename: string) 
{
}

LoadCanvas :: proc(Canvas: ^canvas, Filename: string) 
{
}

NoteColors := []rl.Color {
    rl.LIGHTGRAY,
    rl.YELLOW,
    rl.PINK,
    rl.VIOLET,
    rl.MAROON,
    rl.BEIGE,
    rl.MAGENTA,
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
    Font := rl.LoadFont("/home/ingarsa/.local/share/fonts/d/DroidSansMNFM.ttf")
    if Font == {} 
    {
        fmt.eprintln("Failed to load font!")
        return
    }

    Son.FrameCount = 1
    Son.Canvas.ActiveNoteIdx = -1
    Son.Canvas.HotNoteIdx = -1
    Son.Canvas.Font = Font
    Son.Canvas.Notes = make([dynamic]note)
    fmt.println("Size of keyboard state:", size_of(Son.Keyboard.Keys))

    AddNote(&Son.Canvas, {256, 128})
    AddNote(&Son.Canvas, {768, 128})
    SetNoteText(&Son.Canvas.Notes[len(Son.Canvas.Notes) - 1], "New text!\nNewline")
    SetNoteText(&Son.Canvas.Notes[len(Son.Canvas.Notes) - 2], "New text!\nNewline")

    Canvas := &Son.Canvas
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

        if false || Son.FrameCount % FPS == 0 
        {
            fmt.printfln(
                "LClicked: %v, LDoubleClicked: %v\nRClicked: %v, RDoubleClicked: %v\n",
                Mouse.L.Clicked,
                Mouse.L.DoubleClicked,
                Mouse.R.Clicked,
                Mouse.R.DoubleClicked,
            )
        }

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

            if ActiveNoteMode == .Typing 
            {
                // TODO: (isa): 
                //              Ctrl+[Z, Backspace]
                //              Wrapping text
                //              Single backspace
                //              Cursor
                //              Moving cursor in text
                ExitedTyping := Mouse.L.Pressed && Canvas.HotNoteIdx < 0 || Keys[.Escape].Pressed
                UnsetActiveNoteIfTrue(Canvas, ExitedTyping)

                if !ExitedTyping 
                {
                    // TODO: (isa): Having this framerate dependent is probably not a good idea lol
                    if Keys[.Backspace].Pressed ||
                       Keys[.Backspace].Down && Son.FrameCount % 3 == 0 
                    {
                        BackspaceText(&ActiveNote.Text, 1)
                    }
                     else 
                    {
                        Rune := Keyboard.CharPressed
                        Rune = Keys[.Enter].Pressed ? '\n' : Rune
                        AddRuneToText(&ActiveNote.Text, Rune)
                    }
                }
            }
             else if Canvas.ActiveNoteMode == .Moving 
            {
                UnsetActiveNoteIfTrue(Canvas, Mouse.L.Released)
                Rec.x += ScaledMDelta.x
                Rec.y += ScaledMDelta.y
            }
             else if Canvas.ActiveNoteMode == .Resizing 
            {
                UnsetActiveNoteIfTrue(Canvas, Mouse.L.Released)
                ResizeRecFromCorner(Rec, Canvas.ResizingCorner, ScaledMDelta)
            }
        }
         else if Canvas.HotNoteIdx >= 0 
        {
            if Mouse.L.DoubleClicked 
            {
                SetActiveNote(Canvas, Canvas.HotNoteIdx)
                Canvas.ActiveNoteMode = .Typing
                ResetMouseButtonClicked(&Mouse.L)
            }
             else if Mouse.L.Down && Keys[.Left_Control].Down 
            {
                // TODO: (isa): You have to press the mouse button and then control for this to work,
                // so that needs to be fixed so you can do it in any order
                SetActiveNote(Canvas, Canvas.HotNoteIdx)
                OldActiveNote = Canvas.Notes[Canvas.ActiveNoteIdx]

                if MouseOverCorner 
                {
                    //fmt.printfln("Resizing note from corner: %v", CornerMouseOver)
                    Canvas.ActiveNoteMode = .Resizing
                    Canvas.ResizingCorner = CornerMouseOver
                }
                 else 
                {
                    //fmt.println("Moving note")
                    Canvas.ActiveNoteMode = .Moving
                }
            }
             else if Keyboard.KeyPressed == .D && Keys[.Left_Shift].Down 
            {
                unordered_remove(&Canvas.Notes, Canvas.HotNoteIdx)
                Canvas.HotNoteIdx = -1
                Canvas.HotNote = nil
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
                    //fmt.println("Drawing text outline")
                }
            }

            if i == Canvas.HotNoteIdx 
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
