package son

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import str "core:strings"

//import b2 "vendor:box2d"
import rl "vendor:raylib"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
FPS :: 420
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

corner :: enum {
    TL,
    TR,
    BL,
    BR,
}

note_mode :: enum {
    Idle,
    Moving,
    Resizing,
    Typing,
}

undo_text :: struct {
    CursorPos: int,
    Text:      string,
}

undo :: union {
    undo_text,
    int,
}

TxtBoxUndo :: proc(Box: ^text_box) {
    if len(Box.UndoBuf) == 0 {
        return
    }

    Undo := pop(&Box.UndoBuf)
    switch U in Undo {
    case undo_text:
        TxtBoxClearText(Box)
        TxtBoxAddText(Box, U.Text)
        Box.CursorPos = U.CursorPos
    case int:
        TxtBoxBkspcBytes(Box, U)
    }
    // NOTE: (isa): The above procedures adds the action to the undobuf
    // so this is a hacky way to undo (hihi) that
    // The procs perform memory allocation, so this is pretty bad performance-wise
    pop(&Box.UndoBuf)
}


// TODO: (isa): Should cursor pos be in bytes or runes? (probably bytes)
CURSOR_POS_NONE :: -2
CURSSOR_POS_FRONT :: -1
text_box :: struct {
    Text:      str.Builder,
    CursorPos: int,
    UndoBuf:   [dynamic]undo,
}

CursorPosFromClick :: proc(ClickPos: rl.Vector2, Note: note) -> int {

    return 0
}

/*
 * TODO: 
 * Pinned state where it won't resize or move
 * Store text separately to make search and stuff easier?
*/
note :: struct {
    Rec:           rl.Rectangle,
    RecColor:      rl.Color,
    FontColor:     rl.Color,
    FontSize:      f32,
    Font:          rl.Font,
    using TextBox: text_box,
}

/*
 * Undo note movement and resizing
 */
canvas :: struct {
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

mouse_button_state :: struct {
    Up:            bool,
    Down:          bool,
    Pressed:       bool,
    Released:      bool,
    Clicked:       bool,
    DoubleClicked: bool,
    FrameClicked:  uint,
    ClickPos:      rl.Vector2,
    PrevClickPos:  rl.Vector2,
}

mouse_state :: struct {
    L, R: mouse_button_state,
}

keyboard_key :: enum {
    Left_Control,
    Left_Shift,
    Enter,
    Escape,
    Backspace,
    Up,
    Down,
    Left,
    Right,
}

key_state :: struct {
    Pressed:       bool,
    PressedRepeat: bool,
    Down:          bool,
    Up:            bool,
    Held:          bool,
    FrameHeldFrom: uint,
}

keyboard_state :: struct {
    KeyPressed:  rl.KeyboardKey,
    CharPressed: rune,
    Keys:        [keyboard_key]key_state,
}

Son: son_state
son_state :: struct {
    Initialized: bool,
    FrameCount:  uint,
    Canvas:      ^canvas,
    Mouse:       mouse_state,
    Keyboard:    keyboard_state,
}

NewNoteDim :: proc(
    X, Y: f32,
    Width := NOTE_MIN_DIM.x,
    Height := NOTE_MIN_DIM.y,
    NoteColor := rl.YELLOW,
    FontColor := rl.BLACK,
    FontSize := f32(18),
    Text := "",
    Allocator := context.allocator,
    UndoBufAllocator := context.allocator,
) -> note {
    Note := note{{X, Y, Width, Height}, NoteColor, FontColor, FontSize, {}, {}}
    Note.CursorPos = CURSOR_POS_NONE
    str.builder_init_len(&Note.Text, len(Text), Allocator)
    str.write_string(&Note.Text, Text)
    Note.UndoBuf = make([dynamic]undo, UndoBufAllocator)
    return Note
}

NewNoteRec :: proc(
    Rec: rl.Rectangle,
    NoteColor := rl.YELLOW,
    FontColor := rl.BLACK,
    FontSize := f32(18),
    Text := "",
    Allocator := context.allocator,
    UndoBufAllocator := context.allocator,
) -> note {
    Rec := Rec
    Rec.width = max(Rec.width, NOTE_MIN_DIM.x)
    Rec.height = max(Rec.height, NOTE_MIN_DIM.y)

    Note := note{Rec, NoteColor, FontColor, FontSize, {}, {}}
    Note.CursorPos = CURSOR_POS_NONE
    str.builder_init_len(&Note.Text, len(Text), Allocator)
    str.write_string(&Note.Text, Text)
    Note.UndoBuf = make([dynamic]undo, UndoBufAllocator)

    return Note
}

NewNote :: proc {
    NewNoteDim,
    NewNoteRec,
}

NewCanvas :: proc(Name: string, FontFilename: string, Allocator := context.allocator) -> ^canvas {
    Font := rl.LoadFont(str.clone_to_cstring(FontFilename, context.temp_allocator))
    if Font == {} {
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

DeleteCanvas :: proc(Canvas: ^canvas) {
    delete(Canvas.Name)
    delete(Canvas.FontFilename)
    rl.UnloadFont(Canvas.Font)
    delete(Canvas.Notes)
    free(Canvas)
}

UpdateMouseButtonClicked :: proc(Button: ^mouse_button_state) {
    Button.DoubleClicked = Button.DoubleClicked || (Button.Clicked && Button.Pressed)
    Button.Clicked = Button.Clicked || (!Button.Clicked && Button.Pressed)
    Button.FrameClicked =
        Button.FrameClicked == 0 && Button.Clicked ? Son.FrameCount : Button.FrameClicked
    Button.PrevClickPos = Button.ClickPos
    Button.ClickPos = rl.GetMousePosition()
}

ResetMouseButtonClicked :: proc(Button: ^mouse_button_state) {
    Button.Clicked = false
    Button.DoubleClicked = false
    Button.FrameClicked = 0
}

GetRlMouseButtonState :: proc(ButtonState: ^mouse_button_state, Button: rl.MouseButton) {
    ButtonState.Up = rl.IsMouseButtonReleased(Button)
    ButtonState.Down = rl.IsMouseButtonDown(Button)
    ButtonState.Pressed = rl.IsMouseButtonPressed(Button)
    ButtonState.Released = rl.IsMouseButtonReleased(Button)
}

GetRlKeyboardKeyState :: proc(State: ^key_state, Key: rl.KeyboardKey) {
    State.Pressed = rl.IsKeyPressed(Key)
    State.PressedRepeat = rl.IsKeyPressedRepeat(Key)
    State.Down = rl.IsKeyDown(Key)
    State.Up = rl.IsKeyUp(Key)
}

KeyToRlKey :: proc(Key: keyboard_key) -> rl.KeyboardKey {
    switch Key {
    case .Left_Control:
        return .LEFT_CONTROL
    case .Left_Shift:
        return .LEFT_SHIFT
    case .Enter:
        return .ENTER
    case .Escape:
        return .ESCAPE
    case .Backspace:
        return .BACKSPACE
    case .Up:
        return .UP
    case .Down:
        return .DOWN
    case .Left:
        return .LEFT
    case .Right:
        return .RIGHT
    case:
        return .KEY_NULL
    }
}

IsFrameIntervalWDelay :: proc(From: uint, Interval, Delay: f32) -> bool {
    FrameDelta := SonFrameDelta(From)
    Result :=
        FrameDelta >= SecondsToFrameCount(Delay, FPS) &&
        FrameDelta % SecondsToFrameCount(Interval, FPS) == 0
    return Result
}

SonFrameDelta :: proc(From: uint) -> uint {
    Delta := Son.FrameCount - From
    return Delta
}

UnsetActiveNote :: proc(Canvas: ^canvas) {
    Canvas.ActiveNoteIdx = -1
    Canvas.ActiveNote = nil
    Canvas.ActiveNoteMode = .Idle
}

SetActiveNote :: proc(Canvas: ^canvas, Idx: int) {
    LastIdx := len(Canvas.Notes) - 1
    TopNote := Canvas.Notes[LastIdx]
    NewActiveNote := Canvas.HotNote

    Canvas.Notes[LastIdx] = NewActiveNote^
    Canvas.Notes[Canvas.HotNoteIdx] = TopNote

    Canvas.HotNoteIdx = LastIdx
    Canvas.ActiveNoteIdx = LastIdx
    Canvas.ActiveNote = &Canvas.Notes[Canvas.ActiveNoteIdx]
}

SetHotNote :: proc(Canvas: ^canvas, Idx: int) {
    Canvas.HotNoteIdx = Idx
    Canvas.HotNote = &Canvas.Notes[Idx]
}

UnsetHotNote :: proc(Canvas: ^canvas) {
    Canvas.HotNoteIdx = -1
    Canvas.HotNote = nil
}

AddNote :: proc(Canvas: ^canvas, Note: note) {
    append(&Canvas.Notes, Note)
}

SecondsToFrameCount :: proc(Seconds: f32, Fps: uint) -> uint {
    Count := uint(math.ceil(Seconds * f32(Fps)))
    return Count
}

ResizeRecFromCorner :: proc(Rec: ^rl.Rectangle, Corner: corner, Delta: rl.Vector2) {
    switch Corner {
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
}

RenderNoteTextBox :: proc(Note: ^note, Font: rl.Font) {
    String := str.to_string(Note.Text)
    CString, _ := str.to_cstring(&Note.Text)
    CStringBytes := transmute([^]u8)CString

    WordWrap := true
    DrawPos := rl.Vector2{f32(Note.Rec.x + 5), f32(Note.Rec.y + 5)}

    TextOffsetY, TextOffsetX: f32
    TextLength := i32(rl.TextLength(CString))
    FontBaseSize := f32(Font.baseSize)
    ScaleFactor := Note.FontSize / FontBaseSize
    Spacing := f32(0.5) // TODO(ingar): Make part of note struct

    State := WordWrap ? MeasureDrawState.Measure_State : MeasureDrawState.Draw_State
    MeasureDrawState :: enum {
        Measure_State,
        Draw_State,
    }

    StartLine, EndLine, LastK: i32 = -1, -1, -1
    i, k: i32 = 0, 0
    for i < TextLength {
        CodepointByteCount := i32(0)
        Codepoint := rl.GetCodepoint(cstring(&CStringBytes[i]), &CodepointByteCount)
        Index := rl.GetGlyphIndex(Font, Codepoint)

        if Codepoint == 0x3f {
            CodepointByteCount = 1
        }
        i += CodepointByteCount - 1

        GlyphWidth: f32
        if Codepoint != '\n' {
            GlyphWidth =
                (Font.glyphs[Index].advanceX == 0) ? Font.recs[Index].width * ScaleFactor : f32(Font.glyphs[Index].advanceX) * ScaleFactor
            if i + 1 < TextLength {
                GlyphWidth += Spacing
            }
        }

        switch State {
        case .Measure_State:
            if Codepoint == ' ' || Codepoint == '\t' || Codepoint == '\n' {
                EndLine = i
            }

            if TextOffsetX + GlyphWidth > Note.Rec.width - 10 {
                EndLine = (EndLine < 1) ? i : EndLine
                if i == EndLine {
                    EndLine -= CodepointByteCount
                }
                if StartLine + CodepointByteCount == EndLine {
                    EndLine = i - CodepointByteCount
                }

                State = .Draw_State
            } else if i + 1 == TextLength {
                EndLine = i
                State = .Draw_State
            } else if Codepoint == '\n' {
                State = .Draw_State
            }

            if State == .Draw_State {
                TextOffsetX = 0
                i = StartLine
                GlyphWidth = 0

                Temp := LastK
                LastK = k - 1
                k = Temp
            }
        case .Draw_State:
            if Codepoint == '\n' {
                if !WordWrap {
                    TextOffsetY += (FontBaseSize + FontBaseSize / 2) * ScaleFactor
                    TextOffsetX = 0
                }
            } else {
                if !WordWrap && TextOffsetX + GlyphWidth > Note.Rec.width - 10 {
                    TextOffsetY += (FontBaseSize + FontBaseSize / 2) * ScaleFactor
                    TextOffsetX = 0
                }


                // TODO(ingar): Add drawing of text selection
                IsGlyphSelected := false

                DrawX := DrawPos.x + TextOffsetX
                DrawY := DrawPos.y + TextOffsetY
                if Codepoint != ' ' && Codepoint != '\t' {
                    rl.DrawTextCodepoint(
                        Font,
                        Codepoint,
                        rl.Vector2({DrawX, DrawY}),
                        Note.FontSize,
                        Note.FontColor,
                    )
                }
            }

            if TextOffsetY + FontBaseSize * ScaleFactor > Note.Rec.height - 10 {
                // TODO: (isa): One frame of lag because the text is rendered after the note
                Note.Rec.height += FontBaseSize * ScaleFactor
                //break
            }

            if Note.CursorPos != CURSOR_POS_NONE {
                if int(i) == Note.CursorPos {
                    if Codepoint == '\n' {
                        TextOffsetY += (FontBaseSize + FontBaseSize / 2) * ScaleFactor
                        TextOffsetX = 0
                    }
                    DrawX := DrawPos.x + TextOffsetX
                    DrawY := DrawPos.y + TextOffsetY

                    CursorX := DrawX + GlyphWidth + 2
                    StartPos := rl.Vector2{CursorX, DrawY}
                    EndPos := rl.Vector2{CursorX, (DrawY + (FontBaseSize * ScaleFactor))}
                    rl.DrawLineEx(StartPos, EndPos, 2, rl.BLACK)
                }
            } else if Note.CursorPos == CURSSOR_POS_FRONT {
                rl.DrawLineEx(
                    {DrawPos.x, DrawPos.y},
                    {DrawPos.x, DrawPos.y + (FontBaseSize * ScaleFactor)},
                    2,
                    rl.BLACK,
                )
                // TODO: (isa): Draw before first character
            }

            if WordWrap && i == EndLine {
                TextOffsetY += (FontBaseSize + FontBaseSize / 2) * ScaleFactor
                TextOffsetX = 0
                StartLine = EndLine
                EndLine = -1
                GlyphWidth = 0
                //SelectStart += LastK - k
                k = LastK
                State = .Measure_State
            }
        }

        if TextOffsetX != 0 || Codepoint != ' ' {
            TextOffsetX += GlyphWidth
        }

        i += 1
        k += 1
    }

    if Note.CursorPos != CURSOR_POS_NONE && TextLength == 0 {
        DrawX := DrawPos.x + TextOffsetX
        DrawY := DrawPos.y + TextOffsetY

        CursorX := DrawX + 2
        StartPos := rl.Vector2{CursorX, DrawY}
        EndPos := rl.Vector2{CursorX, (DrawY + (FontBaseSize * ScaleFactor))}
        rl.DrawLineEx(StartPos, EndPos, 2, rl.BLACK)
    }
}

SetNoteText :: proc(Note: ^note, Text: string) {
    str.builder_reset(&Note.Text)
    str.write_string(&Note.Text, Text)
}

AddRuneToText :: proc(Text: ^str.Builder, Rune: rune) {
    if Rune != 0 {
        str.write_rune(Text, Rune)
    }
}

BackspaceRune :: proc(Text: ^str.Builder, Count: int) {
    for _ in 0 ..< Count {
        str.pop_rune(Text)
    }
}

BackspaceByte :: proc(Text: ^str.Builder, Count: int) {
    for _ in 0 ..< Count {
        str.pop_byte(Text)
    }
}

// TODO: (isa): Make relative to CursorPos
TxtBoxAddTextRune :: proc(Box: ^text_box, Rune: rune) {
    Cloned := str.clone(str.to_string(Box.Text), context.temp_allocator)
    str.builder_reset(&Box.Text)
    str.write_string(&Box.Text, Cloned[:Box.CursorPos + 1])
    Written, _ := str.write_rune(&Box.Text, Rune)
    str.write_string(&Box.Text, Cloned[Box.CursorPos + 1:])
    Box.CursorPos += Written
    append(&Box.UndoBuf, Written)
    fmt.printfln("Cursorpos %v, builder len %v", Box.CursorPos, str.builder_len(Box.Text) - 1)
}

TxtBoxAddTextString :: proc(Box: ^text_box, String: string) {
    Cloned := str.clone(str.to_string(Box.Text), context.temp_allocator)
    str.builder_reset(&Box.Text)
    str.write_string(&Box.Text, Cloned[:Box.CursorPos + 1])
    str.write_string(&Box.Text, String)
    str.write_string(&Box.Text, Cloned[Box.CursorPos + 1:])
    Box.CursorPos += len(String)
    append(&Box.UndoBuf, len(String))
}

TxtBoxAddText :: proc {
    TxtBoxAddTextRune,
    TxtBoxAddTextString,
}

// TODO: (isa): Make relative to cursor
TxtBoxBkspcBytes :: proc(Box: ^text_box, Count: int, Allocator := context.allocator) {
    append(&Box.UndoBuf, undo_text{Box.CursorPos, str.clone(str.to_string(Box.Text), Allocator)})
    for _ in 0 ..< Count {
        str.pop_byte(&Box.Text)
    }

    Box.CursorPos -= Count
}

TxtBoxBkspcRunes :: proc(Box: ^text_box, Count: int, Allocator := context.allocator) {
    append(&Box.UndoBuf, undo_text{Box.CursorPos, str.clone(str.to_string(Box.Text), Allocator)})
    for _ in 0 ..< Count {
        _, Width := str.pop_rune(&Box.Text)
        Box.CursorPos -= Width
    }
}

TxtBoxClearText :: proc(Box: ^text_box) {
    str.builder_reset(&Box.Text)
    Box.CursorPos = CURSSOR_POS_FRONT
}

DrawNoteOutline :: proc(Note: note) {
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

DrawCornerLines :: proc(Note: note, Corner: corner, MousePos: rl.Vector2) {
    Rec := Note.Rec
    switch Corner {
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
) -> Maybe(corner) {
    TLRec := rl.Rectangle{Rec.x, Rec.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, TLRec) {
        return .TL
    }

    TRRec := rl.Rectangle{Rec.x + Rec.width - CornerDims.x, Rec.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, TRRec) {
        return .TR
    }

    BLRec := rl.Rectangle{Rec.x, Rec.y + Rec.height - CornerDims.y, CornerDims.x, CornerDims.y}
    if rl.CheckCollisionPointRec(Point, BLRec) {
        return .BL
    }

    BRRec := rl.Rectangle {
        Rec.x + Rec.width - CornerDims.x,
        Rec.y + Rec.height - CornerDims.y,
        CornerDims.x,
        CornerDims.y,
    }
    if rl.CheckCollisionPointRec(Point, BRRec) {
        return .BR
    }

    return nil
}

RlRecAdd :: proc(Rec1: rl.Rectangle, Addend: [4]f32) -> rl.Rectangle {
    NewRec := rl.Rectangle {
        Rec1.x + Addend[0],
        Rec1.y + Addend[1],
        Rec1.width + Addend[2],
        Rec1.height + Addend[3],
    }
    return NewRec
}

IncrementOffsetsByTypeVal :: proc(From, To: ^int, $F: typeid, TInc: int) {
    From^ += size_of(F)
    To^ += TInc
}

IncrementOffsetsByValType :: proc(From, To: ^int, FInc: int, $T: typeid) {
    From^ += FInc
    To^ += size_of(T)
}

IncrementOffsetsByType :: proc(From, To: ^int, $F: typeid, $T: typeid) {
    From^ += size_of(F)
    To^ += size_of(T)
}

IncrementOffsetsByVal :: proc(From, To: ^int, FInc, TInc: int) {
    From^ += FInc
    To^ += TInc
}

IncrementOffsets :: proc {
    IncrementOffsetsByTypeVal,
    IncrementOffsetsByValType,
    IncrementOffsetsByVal,
    IncrementOffsetsByType,
}

SliceToTypeOffset :: proc(Buf: []byte, $T: typeid, Off: ^int) -> T {
    Val := slice.to_type(Buf[Off^:], T)
    Off^ += size_of(T)
    return Val
}

SliceToStringOffset :: proc(Buf: []byte, StringLen: int, Off: ^int) -> string {
    String := string(Buf[Off^:Off^ + StringLen])
    Off^ += StringLen
    return String
}

// TODO: (isa): Figure out how to do ~ for home directory in Odin
DEFAULT_SAVE_DIR :: "/home/ingarsa/stickOnote/saves/"
CANVAS_EXTENSION :: ".soncanv"

SaveCanvas :: proc(
    Canvas: ^canvas,
    DirectoryName := DEFAULT_SAVE_DIR,
    Allocator := context.temp_allocator,
) -> (
    Err: os.Error,
) {
    DirectoryExists := os.is_dir_path(DirectoryName)
    if DirectoryName != DEFAULT_SAVE_DIR && !DirectoryExists {
        return os.ENOENT
    } else if DirectoryName == DEFAULT_SAVE_DIR && !DirectoryExists {
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

    for &Note in Canvas.Notes {
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
    UndoBufAllocator := context.allocator,
    TempAllocator := context.temp_allocator,
) -> (
    Canvas: ^canvas,
    Err: os.Error,
) {
    if !os.is_dir_path(DirectoryName) {
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

    for i in 0 ..< NoteCount {
        Note: note
        Rec := SliceToTypeOffset(Bytes, type_of(Note.Rec), &Off)
        RecColor := SliceToTypeOffset(Bytes, type_of(Note.RecColor), &Off)
        FontColor := SliceToTypeOffset(Bytes, type_of(Note.FontColor), &Off)
        FontSize := SliceToTypeOffset(Bytes, type_of(Note.FontSize), &Off)
        TextSize = SliceToTypeOffset(Bytes, int, &Off)
        Text := SliceToStringOffset(Bytes, TextSize, &Off)

        Note = NewNote(Rec, RecColor, FontColor, FontSize)
        str.write_string(&Note.Text, Text)
        append(&Canvas.Notes, Note)
    }

    fmt.printfln(
        "Successfully loaded canvas \"%v\" from \"%v\"",
        Canvas.Name,
        str.to_string(FilenameB),
    )

    return Canvas, os.ERROR_NONE
}


TrackingAllocatorFini :: proc(Track: ^mem.Tracking_Allocator) {
    if len(Track.allocation_map) > 0 {
        for _, Entry in Track.allocation_map {
            fmt.eprintfln("%v leaked %v bytes\n", Entry.location, Entry.size)
        }
    }

    mem.tracking_allocator_destroy(Track)
}


main :: proc() {
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
    if LoadErr != os.ERROR_NONE {
        if LoadErr == os.ENOENT {
            Canvas = NewCanvas("Testing", "/home/ingarsa/.local/share/fonts/d/DroidSansMNFM.ttf")
            Text := "Failed to load canvas Testing from file!\nIt did not exist"
            AddNote(Canvas, NewNote(768, 128, Text = Text))
        } else {
            fmt.eprintfln("Failed to load canvas Testing (error %v)", LoadErr)
        }
    }

    fmt.println("Size of multipointer:", size_of(note))

    Son.Canvas = Canvas
    Mouse := &Son.Mouse
    Keyboard := &Son.Keyboard
    Keys := &Keyboard.Keys

    LeftCtrl := &Keys[.Left_Control]
    LeftShift := &Keys[.Left_Shift]
    Enter := &Keys[.Enter]
    Escape := &Keys[.Escape]
    Backspace := &Keys[.Backspace]
    UpArr := &Keys[.Up]
    DownArr := &Keys[.Down]
    LeftArr := &Keys[.Left]
    RightArr := &Keys[.Right]

    for !rl.WindowShouldClose() {
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
           SonFrameDelta(Mouse.L.FrameClicked) >= RESET_CLICKED_FRAME_COUNT {
            ResetMouseButtonClicked(&Mouse.L)
        }

        if Mouse.R.FrameClicked != 0 &&
           SonFrameDelta(Mouse.R.FrameClicked) >= RESET_CLICKED_FRAME_COUNT {
            ResetMouseButtonClicked(&Mouse.R)
        }

        UpdateMouseButtonClicked(&Mouse.L)
        UpdateMouseButtonClicked(&Mouse.R)

        Camera.zoom += rl.GetMouseWheelMove() * 0.15 * Camera.zoom
        if Camera.zoom <= 0.05 {
            Camera.zoom = 0.05
        }

        if Mouse.R.Down {
            Camera.target -= ScaledMDelta
        }

        Keyboard.CharPressed = rl.GetCharPressed()
        Keyboard.KeyPressed = rl.GetKeyPressed()
        for &Key, Type in Keys {
            DownLastFrame := Key.Down
            RlKey := KeyToRlKey(Type)
            GetRlKeyboardKeyState(&Key, RlKey)
            Key.Held = DownLastFrame && Key.Down
            if Key.FrameHeldFrom == 0 && Key.Held {
                Key.FrameHeldFrom = Son.FrameCount - 1
            } else if !Key.Held {
                Key.FrameHeldFrom = 0
            }

            if Son.FrameCount % 20 == 0 && Type == .Backspace {
                //fmt.println(Key, Type)
            }
        }

        if Keyboard.KeyPressed == .ZERO {
            Camera.target = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.offset = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.zoom = 1
        } else if Canvas.ActiveNoteMode == .Idle && LeftShift.Down && Keyboard.KeyPressed == .N {
            NoteColor := NoteColors[Son.FrameCount % len(NoteColors)]
            AddNote(Canvas, NewNote(MouseWorldPos.x, MouseWorldPos.y, NoteColor = NoteColor))
            SetNoteText(&Canvas.Notes[len(Canvas.Notes) - 1], "New Note!")
        } else if Canvas.ActiveNoteMode == .Idle && LeftCtrl.Down && Keyboard.KeyPressed == .S {
            if SaveErr := SaveCanvas(Son.Canvas); SaveErr != os.ERROR_NONE {
                fmt.eprintfln("Failed to save canvas \"%v\" (error %v)", Son.Canvas.Name, SaveErr)
                return
            }
        } else if Canvas.ActiveNoteMode == .Idle && LeftCtrl.Down && Keyboard.KeyPressed == .L {
            if LoadedCanvas, LoadErr := LoadCanvas(Son.Canvas.Name); LoadErr == os.ERROR_NONE {
                DeleteCanvas(Son.Canvas)
                Son.Canvas = LoadedCanvas
                Canvas = LoadedCanvas
            } else {
                fmt.eprintfln("Failed to load canvas \"%v\" (error %v)", Son.Canvas.Name, LoadErr)
                return
            }
        }

        UnsetHotNote(Canvas)
        MouseOverCorner: bool
        CornerMouseOver: corner
        #reverse for &Note, i in Canvas.Notes {
            MouseOverNote := rl.CheckCollisionPointRec(MouseWorldPos, Note.Rec)
            if MouseOverNote {
                SetHotNote(Canvas, i)
                CornerMouseOver, MouseOverCorner =
                CollisionPointRecCorner(MouseWorldPos, Note.Rec, CORNER_CHECK_DIMS).?
                break
            }
        }

        if Canvas.ActiveNoteIdx >= 0 {
            ActiveNote := Canvas.ActiveNote
            Rec := &Canvas.ActiveNote.Rec

            switch Canvas.ActiveNoteMode {
            case .Idle:
            case .Typing:
                // TODO: (isa): 
                //              Ctrl+Z
                //              Wrapping text
                //              Cursor
                //              Moving cursor in text
                ExitedTyping := Mouse.L.Pressed && Canvas.HotNoteIdx < 0 || Escape.Pressed
                if ExitedTyping {
                    ActiveNote.CursorPos = CURSOR_POS_NONE
                    UnsetActiveNote(Canvas)
                    break
                }

                ActiveNote.CursorPos =
                    ActiveNote.CursorPos != CURSOR_POS_NONE ? ActiveNote.CursorPos : str.builder_len(ActiveNote.Text) - 1

                if Backspace.Pressed {
                    if LeftCtrl.Down {
                        Text := str.to_string(ActiveNote.Text)
                        LastByte := str.builder_len(ActiveNote.Text) - 1
                        LastNewLineOffset := str.last_index(Text, "\n")
                        LastSpaceOffset := str.last_index(Text, " ")

                        if LastNewLineOffset == -1 && LastSpaceOffset == -1 {
                            TxtBoxClearText(&ActiveNote.TextBox)
                        } else if LastSpaceOffset == LastByte || LastNewLineOffset == LastByte {
                            TxtBoxBkspcRunes(&ActiveNote.TextBox, 1)
                        } else {
                            Offset := max(LastSpaceOffset, LastNewLineOffset) + 1
                            BytesToPop := str.builder_len(ActiveNote.Text) - Offset
                            TxtBoxBkspcBytes(&ActiveNote.TextBox, BytesToPop)
                        }
                    } else {
                        TxtBoxBkspcRunes(&ActiveNote.TextBox, 1)
                    }
                } else if Backspace.Held &&
                   SonFrameDelta(Backspace.FrameHeldFrom) >= SecondsToFrameCount(0.35, FPS) &&
                   SonFrameDelta(Backspace.FrameHeldFrom) % SecondsToFrameCount(0.05, FPS) == 0 {
                    TxtBoxBkspcRunes(&ActiveNote.TextBox, 1)
                } else if LeftCtrl.Down && Keyboard.KeyPressed == .Z {
                    TxtBoxUndo(&ActiveNote.TextBox)
                } else if LeftCtrl.Down && Keyboard.KeyPressed == .Y {
                } else if UpArr.Pressed ||
                   (UpArr.Held && IsFrameIntervalWDelay(UpArr.FrameHeldFrom, 0.05, 0.35)) {
                } else if DownArr.Pressed ||
                   (DownArr.Held && IsFrameIntervalWDelay(DownArr.FrameHeldFrom, 0.05, 0.35)) {
                } else if LeftArr.Pressed ||
                   (LeftArr.Held && IsFrameIntervalWDelay(LeftArr.FrameHeldFrom, 0.05, 0.35)) {
                    ActiveNote.CursorPos = max(CURSSOR_POS_FRONT, ActiveNote.CursorPos - 1)
                } else if RightArr.Pressed ||
                   (RightArr.Held && IsFrameIntervalWDelay(RightArr.FrameHeldFrom, 0.05, 0.35)) {
                    ActiveNote.CursorPos = min(
                        str.builder_len(ActiveNote.Text) - 1,
                        ActiveNote.CursorPos + 1,
                    )
                } else {
                    Rune := Keyboard.CharPressed
                    Rune = Enter.Pressed ? '\n' : Rune
                    if Rune != 0 {
                        TxtBoxAddText(&ActiveNote.TextBox, Rune)
                    }
                }

            case .Moving:
                if Mouse.L.Released {
                    UnsetActiveNote(Canvas)
                    break
                }

                Rec.x += ScaledMDelta.x
                Rec.y += ScaledMDelta.y

            case .Resizing:
                if Mouse.L.Released {
                    UnsetActiveNote(Canvas)
                    break
                }

                ResizeRecFromCorner(Rec, Canvas.ResizingCorner, ScaledMDelta)
            }
        } else if Canvas.HotNoteIdx >= 0 {
            // TODO: (isa): Check that both clicks were inside the note. 
            // Currently it activates even if the first click was outside it.
            // TODO: (isa): Also, double clicking on another note while in text mode on another
            // does not switch focus
            if Mouse.L.DoubleClicked {
                SetActiveNote(Canvas, Canvas.HotNoteIdx)
                Canvas.ActiveNoteMode = .Typing
                ResetMouseButtonClicked(&Mouse.L)
            } else if Mouse.L.Down {
                SetActiveNote(Canvas, Canvas.HotNoteIdx)

                if MouseOverCorner {
                    Canvas.ActiveNoteMode = .Resizing
                    Canvas.ResizingCorner = CornerMouseOver
                } else {
                    Canvas.ActiveNoteMode = .Moving
                }
            } else if Keyboard.KeyPressed == .D && LeftShift.Down {
                unordered_remove(&Canvas.Notes, Canvas.HotNoteIdx)
                UnsetHotNote(Canvas)
            }
        }

        for &Note, i in Canvas.Notes {
            rl.DrawRectangleRec(Note.Rec, Note.RecColor)
            RenderNoteTextBox(&Note, Canvas.Font)

            if i == Canvas.ActiveNoteIdx {
                DrawNoteOutline(Note)
                if Canvas.ActiveNoteMode == .Resizing {
                    DrawCornerLines(Note, Canvas.ResizingCorner, MouseWorldPos)
                } else if Canvas.ActiveNoteMode == .Typing {
                    RecOffset := f32(NOTE_TEXT_OFFSET - 2)
                    TextRec := RlRecAdd(
                        Note.Rec,
                        {RecOffset, RecOffset, -2 * RecOffset, -2 * RecOffset},
                    )
                    rl.DrawRectangleLinesEx(TextRec, 1, rl.BLACK)
                }
            } else if i == Canvas.HotNoteIdx {
                DrawNoteOutline(Note)
                if MouseOverCorner {
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
