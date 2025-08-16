/*
    Copyright (c) 2024 Ingar Solveigson Asheim
    This file is part of StickO-Note, available under a custom license.
    See the LICENSE file in the root directory for full license details.
*/

package son


import "core:fmt"
import "core:mem"
import "core:os"
import str "core:strings"

import b2 "vendor:box2d"
import rl "vendor:raylib"

WINDOW_WIDTH :: 960
WINDOW_HEIGHT :: 540
SON_NOTE_COUNT :: 1024
NOTE_TEXT_BUFFER_LEN :: 256

note :: struct {
    Rect:       rl.Rectangle,
    RectColor:  rl.Color,
    TextColor:  rl.Color,
    Font:       rl.Font,
    FontSize:   f32,
    Text:       str.Builder,
    TextBuffer: [NOTE_TEXT_BUFFER_LEN]u8,
    // TODO(ingar): Find a better way to allocate the text buffer, ideally dynamically
}

note_collection :: struct {
    Size:           u64,
    Count:          u64,
    SelectedNote:   uint,
    // HotNote TODO(ingar): See casey's video on imgui again
    NoteIsSelected: bool,
    Notes:          []note,
}

canvas :: struct {
    Arena:          mem.Arena,
    Allocator:      mem.Allocator,
    Id:             int,
    CollectionSize: u64,
    NoteCollection: ^note_collection,
    Font:           rl.Font,
}

mouse_event :: struct {
    Button: rl.MouseButton,
    Pos:    rl.Vector2,
}

mouse_state :: struct {
    LClicked:      bool,
    RClicked:      bool,
    PrevLClickPos: rl.Vector2,
    PrevRClickPos: rl.Vector2,
}

son_state :: struct {
    Initialized:  bool,
    Allocator:    mem.Allocator,
    MouseState:   ^mouse_state,
    Canvases:     []^canvas,
    ActiveCanvas: ^canvas,
}

CreateCanvas :: proc(NoteCount: u64, Id: int, Allocator := context.allocator) -> ^canvas {
    CollectionSize := size_of(note_collection) + NoteCount * size_of(note)
    CanvasMemSize := size_of(canvas) + CollectionSize
    CanvasMemory, MemErr := make([]u8, CanvasMemSize)
    CanvasArena: mem.Arena
    mem.arena_init(&CanvasArena, CanvasMemory)
    CanvasAllocator := mem.arena_allocator(&CanvasArena)

    Canvas := new(canvas, CanvasAllocator)
    NoteCollection := new(note_collection, CanvasAllocator)
    Notes := make([]note, NoteCount, CanvasAllocator)
    fmt.println(
        "Canvas adr:",
        rawptr(Canvas),
        "\nNote collection adr:",
        rawptr(NoteCollection),
        "\nNotes adr:",
        rawptr(&Notes[0]),
        "\n",
    )

    NoteCollection.Size = NoteCount
    NoteCollection.Notes = Notes

    Canvas.Arena = CanvasArena
    Canvas.Allocator = CanvasAllocator
    Canvas.CollectionSize = CollectionSize
    Canvas.NoteCollection = NoteCollection
    Canvas.Font = rl.LoadFont("/home/ingarsa/.local/share/fonts/d/DroidSansMNFM.ttf")

    return Canvas
}

/*
 * Based on the raylib example:
 * https://github.com/raysan5/raylib/blob/master/examples/text/text_rectangle_bounds.c
 */
// TODO(ingar): Instead of rendering by going through the code-points, I think it would be a 
// sensible idea to implement my initial idea of wrapping the string and then using rl.DrawText 
// instead. I'm not positive on this, but maybe DrawText will look less shit
RenderNoteText :: proc(Note: ^note) {
    String := str.to_string(Note.Text)
    CString, _ := str.to_cstring(&Note.Text)
    CStringBytes := transmute([^]u8)CString

    WordWrap := true
    DrawPos := rl.Vector2{f32(Note.Rect.x + 5), f32(Note.Rect.y + 5)}
    TextLength := i32(rl.TextLength(CString))
    TextOffsetY := f32(0)
    TextOffsetX := f32(0)
    ScaleFactor := Note.FontSize / f32(Note.Font.baseSize)
    Spacing := f32(0.5) // TODO(ingar): Make part of note struct

    MeasureDrawState :: enum {
        Measure_State,
        Draw_State,
    }
    State := MeasureDrawState.Measure_State if WordWrap else MeasureDrawState.Draw_State

    StartLine, EndLine, LastK: i32 = -1, -1, -1
    i, k: i32 = 0, 0
    for i < TextLength {
        CodepointByteCount := i32(0)
        Codepoint := rl.GetCodepoint(cstring(&CStringBytes[i]), &CodepointByteCount)
        Index := rl.GetGlyphIndex(Note.Font, Codepoint)

        if Codepoint == 0x3f {
            CodepointByteCount = 1
        }
        i += CodepointByteCount - 1

        GlyphWidth := f32(0)
        if Codepoint != '\n' {
            GlyphWidth =
                (Note.Font.glyphs[Index].advanceX == 0) ? Note.Font.recs[Index].width * ScaleFactor : f32(Note.Font.glyphs[Index].advanceX) * ScaleFactor
            if i + 1 < TextLength {
                GlyphWidth += Spacing
            }
        }

        switch State {
        case .Measure_State:
            if Codepoint == ' ' || Codepoint == '\t' || Codepoint == '\n' {
                EndLine = i
            }

            if TextOffsetX + GlyphWidth > Note.Rect.width - 10 {
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
                    TextOffsetY += f32(Note.Font.baseSize + Note.Font.baseSize / 2) * ScaleFactor
                    TextOffsetX = 0
                }
            } else {
                if !WordWrap && TextOffsetX + GlyphWidth > Note.Rect.width - 10 {
                    TextOffsetY += f32(Note.Font.baseSize + Note.Font.baseSize / 2) * ScaleFactor
                    TextOffsetX = 0
                }

                // NOTE(ingar): Stop drawing if text goes out of bounds
                if TextOffsetY + f32(Note.Font.baseSize) * ScaleFactor > Note.Rect.height - 10 {
                    break
                }

                // TODO(ingar): Add drawing of text selection
                IsGlyphSelected := false

                DrawX := DrawPos.x + TextOffsetX
                DrawY := DrawPos.y + TextOffsetY
                if Codepoint != ' ' && Codepoint != '\t' {
                    rl.DrawTextCodepoint(
                        Note.Font,
                        Codepoint,
                        rl.Vector2({DrawX, DrawY}),
                        Note.FontSize,
                        Note.TextColor,
                    )
                }
            }

            if WordWrap && i == EndLine {
                // TODO(ingar): Since baseSize is i32, the scaling might be off due to the integer division
                TextOffsetY += f32(Note.Font.baseSize + Note.Font.baseSize / 2) * ScaleFactor
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
}

// TODO(ingar): The text on certain notes isn't rendered if a note earlier in the collection
// array is removed
RemoveNote :: proc(Collection: ^note_collection, Idx: u64) {
    // NOTE(ingar): Error handling
    if Collection.Count == 1 {
        Collection.Count = 0
        return
    }

    if Idx < Collection.Count {
        copy(Collection.Notes[Idx:], Collection.Notes[Idx + 1:])
        Collection.Count -= 1
    }
}

AddNewNote :: proc(Canvas: ^canvas, Coord1, Coord2: rl.Vector2, Color: rl.Color) {
    if Coord1.x == Coord2.x || Coord1.y == Coord2.y {
        return // NOTE(ingar): Add error?
    }

    Collection := Canvas.NoteCollection
    if Collection.Count < Collection.Size {
        LeftX := Coord1.x if Coord1.x < Coord2.x else Coord2.x
        RightX := Coord1.x if Coord1.x > Coord2.x else Coord2.x
        TopY := Coord1.y if Coord1.y < Coord2.y else Coord2.y
        BottomY := Coord1.y if Coord1.y > Coord2.y else Coord2.y

        Width := RightX - LeftX
        Height := BottomY - TopY

        Note := &Collection.Notes[Collection.Count]

        Note.Rect = {LeftX, TopY, Width, Height}
        Note.RectColor = Color
        Note.Font = Canvas.Font
        Note.FontSize = 32
        Note.TextColor = rl.BLACK
        Note.Text = str.builder_from_bytes(Note.TextBuffer[:])
        str.write_string(&Note.Text, "Toodiloo!\nNewline baby!")

        Collection.Count += 1
    }
}

LoadCanvasFromFile :: proc(Canvas: ^canvas) {
    StringBuilder := str.builder_make(context.temp_allocator)
    str.write_string(&StringBuilder, "./CanvasSaveFiles/Canvas")
    str.write_int(&StringBuilder, Canvas.Id)
    FileName := str.to_string(StringBuilder)

    File, OpenError := os.open(FileName, os.O_RDONLY)
    if OpenError != os.ERROR_NONE {
        fmt.println("Error opening file!", OpenError)
        return}
    defer os.close(File)

    FileInfo, StatError := os.fstat(File, context.temp_allocator)
    if StatError != os.ERROR_NONE {
        fmt.println("Error getting file info!", StatError)
        return
    }

    fmt.println(
        "Canvas adr:",
        rawptr(Canvas),
        "\nNote collection adr:",
        rawptr(Canvas.NoteCollection),
        "\nNotes adr:",
        rawptr(&Canvas.NoteCollection.Notes[0]),
        "\n",
    )

    Read, ReadError := os.read_ptr(File, Canvas.NoteCollection, int(FileInfo.size)) // int(Canvas.CollectionSize))
    if ReadError != os.ERROR_NONE {
        fmt.println("Error reading from file!", ReadError)
        return
    }

    // TODO(ingar): This is probably a terrible way of doing this!
}

SaveCanvasToFile :: proc(Canvas: ^canvas) {
    StringBuilder := str.builder_make(context.temp_allocator)
    str.write_string(&StringBuilder, "./CanvasSaveFiles/Canvas")
    str.write_int(&StringBuilder, Canvas.Id)
    FileName := str.to_string(StringBuilder)

    RWE_PERMISSION :: 0o755
    File, OpenError := os.open(FileName, os.O_WRONLY | os.O_CREATE, RWE_PERMISSION)
    if OpenError != os.ERROR_NONE {
        fmt.println("Error opening file!", OpenError)
        return
    }
    defer os.close(File)

    BytesWritten, WriteError := os.write_ptr(
        File,
        Canvas.NoteCollection,
        int(Canvas.CollectionSize),
    )
    if WriteError != os.ERROR_NONE {
        fmt.println("Error writing to file!", WriteError)
    } else {
        fmt.println("Wrote", BytesWritten, "bytes to file")
    }
}

foo :: proc() {
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "StickO-Note")
    rl.SetTargetFPS(60)
    rl.SetWindowMonitor(0)
    WindowConfig := rl.ConfigFlags{.WINDOW_RESIZABLE}
    rl.SetWindowState(WindowConfig)

    SonState := new(son_state)
    MouseState := new(mouse_state)
    CANVAS_COUNT :: 1
    CanvasSlice := make([]^canvas, CANVAS_COUNT)

    SonState.Allocator = mem.nil_allocator()
    SonState.MouseState = MouseState
    SonState.Canvases = CanvasSlice
    SonState.Initialized = true

    NOTE_COUNT :: 128
    for i in 0 ..< len(SonState.Canvases) {
        Canvas := CreateCanvas(NOTE_COUNT, i)
        SonState.Canvases[i] = Canvas
    }
    SonState.ActiveCanvas = SonState.Canvases[0]

    TextColor := rl.BLACK
    // NOTE(ingar): Used in debugging to get different color for notes. Will be removed in final version.
    Colors := []rl.Color {
        rl.LIGHTGRAY,
        rl.YELLOW,
        rl.PINK,
        rl.VIOLET,
        rl.MAROON,
        rl.BEIGE,
        rl.MAGENTA,
    }

    Camera := rl.Camera2D{}
    Camera.target = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
    Camera.offset = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
    Camera.zoom = 1

    FrameCount := 0
    for !rl.WindowShouldClose() {
        CurrentScreenWorldPos := rl.GetScreenToWorld2D(Camera.target, Camera)
        MouseScreenPos := rl.GetMousePosition()
        MouseWorldPos := rl.GetScreenToWorld2D(MouseScreenPos, Camera)
        ActiveCanvas := SonState.ActiveCanvas

        if rl.IsMouseButtonPressed(.LEFT) {
            SonState.MouseState.LClicked = true
            SonState.MouseState.PrevLClickPos = MouseWorldPos
        }

        if rl.IsMouseButtonReleased(.LEFT) {
            if SonState.MouseState.LClicked {
                NoteColor := Colors[FrameCount % len(Colors)]
                AddNewNote(
                    ActiveCanvas,
                    SonState.MouseState.PrevLClickPos,
                    MouseWorldPos,
                    NoteColor,
                )
                SonState.MouseState.LClicked = false
            }
        }

        if rl.IsMouseButtonDown(.RIGHT) {
            MouseDelta := rl.GetMouseDelta()
            Camera.target -= MouseDelta / Camera.zoom
        }

        if rl.IsKeyPressed(.ZERO) {
            Camera.target = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.offset = {WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2}
            Camera.zoom = 1
        }

        if rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyPressed(.S) {
            SaveCanvasToFile(ActiveCanvas)
        }

        if rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyPressed(.L) {
            LoadCanvasFromFile(ActiveCanvas)}

        Camera.zoom += rl.GetMouseWheelMove() * 0.15 * Camera.zoom
        if Camera.zoom <= 0.05 {
            Camera.zoom = 0.05
        }


        if FrameCount % 144 == 0 && false {
            fmt.println(
                "Mouse world pos:",
                MouseWorldPos,
                "\nScreen world pos:",
                CurrentScreenWorldPos,
                "\nCamera:",
                Camera,
                "\n",
            )
        }

        /*******************/
        /*    RENDERING    */
        /*******************/

        WindowWidth := rl.GetScreenWidth()
        WindowHeight := rl.GetScreenHeight()

        rl.BeginDrawing()
        rl.BeginMode2D(Camera)

        rl.ClearBackground(rl.DARKGRAY)
        rl.DrawText("Hellope!", WINDOW_WIDTH / 2 - 50, WINDOW_HEIGHT / 2 - 50, 20, TextColor)

        TopMostNote := -1
        for &Note, i in ActiveCanvas.NoteCollection.Notes[:ActiveCanvas.NoteCollection.Count] {
            MouseIsOverNote := rl.CheckCollisionPointRec(MouseWorldPos, Note.Rect)
            if MouseIsOverNote {
                // TODO(ingar): Highlights all notes under mouse, not just top-most
                OutlineWidth := f32(8) + Note.Rect.width / 50 + Note.Rect.height / 50
                Outline := rl.Rectangle {
                    Note.Rect.x - OutlineWidth,
                    Note.Rect.y - OutlineWidth,
                    Note.Rect.width + 2 * OutlineWidth,
                    Note.Rect.height + 2 * OutlineWidth,
                }
                OutlineColor := Note.RectColor
                OutlineColor.a = 100
                //OutlineWidth := 5 + Note.Rect.width / 50 + Note.Rect.height / 50

                //rl.DrawRectangleRoundedLines(Outline, 0.05, 0, ShadowWidth, ShadowColor)
                rl.DrawRectangleLinesEx(Outline, OutlineWidth, OutlineColor)
                rl.DrawRectangleRec(Note.Rect, Note.RectColor)
                RenderNoteText(&Note)

                // NOTE(ingar): Ensures only the top-most one is deleted if there are overlapping notes
                if rl.IsKeyPressed(.D) {
                    TopMostNote = i
                }
            } else {
                rl.DrawRectangleRec(Note.Rect, Note.RectColor)
                RenderNoteText(&Note)
            }
        }

        // NOTE(ingar): Camera target target lines
        rl.DrawLine(
            i32(Camera.target.x),
            -WindowHeight * 10,
            i32(Camera.target.x),
            WindowHeight * 10,
            rl.GREEN,
        )
        rl.DrawLine(
            -WindowWidth * 10,
            i32(Camera.target.y),
            WindowWidth * 10,
            i32(Camera.target.y),
            rl.GREEN,
        )

        rl.DrawFPS(
            i32(Camera.target.x - WINDOW_WIDTH / 2 + 10),
            i32(Camera.target.y - WINDOW_HEIGHT / 2 + 10),
        )

        rl.EndMode2D()
        rl.EndDrawing()

        /**********************/
        /*    EO RENDERING    */
        /**********************/

        if TopMostNote >= 0 {
            RemoveNote(ActiveCanvas.NoteCollection, u64(TopMostNote))
            TopMostNote = -1
        }

        free_all(context.temp_allocator)
        FrameCount += 1
    }

    rl.CloseWindow()
}
