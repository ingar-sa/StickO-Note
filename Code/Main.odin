/*
    Copyright (c) 2024 Ingar Solveigson Asheim
    This file is part of StickO-Note, available under a custom license.
    See the LICENSE file in the root directory for full license details.
*/

package son


import "core:fmt"
import "core:mem"
import str "core:strings"

import rl "vendor:raylib"

WINDOW_WIDTH :: 960
WINDOW_HEIGHT :: 540
SON_NOTE_COUNT :: 1024

text_field :: struct {
    Rect:      rl.Rectangle,
    TextColor: rl.Color,
    Font:      rl.Font,
    FontSize:  i32,
    Text:      string,
}

// NOTE(ingar): I want to add shadows to indicate z-difference
note :: struct {
    Rect:      rl.Rectangle,
    Color:     rl.Color,
    TextField: text_field,
    Z:         i64,
    // NOTE(ingar): If you create one note every second, it will take
    // 292.27 billion years for this variable to overflow, so I think it's good
}

// NOTE(ingar): This might be what will be refactored into the canvas later.
note_collection :: struct {
    Size:           u64,
    Count:          u64,
    SelectedNote:   uint,
    // HotNote TODO(ingar): See casey's video on imgui again
    NoteIsSelected: bool,
    Notes:          []note,
}

AllocateNoteCollection :: proc(Size: u64, Allocator := context.allocator) -> ^note_collection {
    Collection := new(note_collection, Allocator)
    Collection.Size = Size
    Collection.Notes = make([]note, Size, Allocator)

    return Collection
}

RenderTextField :: proc(Field: ^text_field) {
    CString := str.clone_to_cstring(Field.Text, context.temp_allocator)
    DrawPos := rl.Vector2{f32(Field.Rect.x), f32(Field.Rect.y)}
    rl.DrawTextEx(
        Field.Font,
        CString,
        DrawPos,
        f32(Field.FontSize),
        /* 1 seems to be correct, but should be obs about this in the future */
        1,
        Field.TextColor,
    )
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
    Initialized:    bool,
    MouseState:     ^mouse_state,
    NoteCollection: ^note_collection,
}

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
// GlyphInfo{value = !, offsetX = 0, offsetY = 0, advanceX = 0, image = Image{data = 0xB6F850, width = 1, height = 10, mipmaps = 1, format = "UNCOMPRESSED_GRAY_ALPHA"}}
WrapTextFieldString :: proc(Field: ^text_field) {
    if len(Field.Text) == 0 {
        return
    }

    FieldWidth := i32(Field.Rect.width)
    FieldHeight := i32(Field.Rect.height)
    RemainingWidth := FieldWidth

    GlyphInfo := rl.GetGlyphInfo(Field.Font, rune(Field.Text[0]))
    // NOTE(ingar): Does the image width take the spacing into account, and height line "aspacing"?

    LinesAvailable := FieldHeight / GlyphInfo.image.height
    RemainingLines := LinesAvailable
    RemainingWidth -= GlyphInfo.image.width

    fmt.println(Field.Font)
    fmt.println(GlyphInfo)
    fmt.println(LinesAvailable)

    StringBuilder: str.Builder
    str.builder_init(&StringBuilder)
    defer str.builder_destroy(&StringBuilder)
    str.write_rune(&StringBuilder, rune(Field.Text[0]))

    for Rune in Field.Text[1:] {
        if Rune == '\n' {
            str.write_rune(&StringBuilder, Rune)
            RemainingWidth = FieldWidth
            RemainingLines -= 1
            continue
        }

        GlyphInfo = rl.GetGlyphInfo(Field.Font, Rune)
        GlyphWidth := GlyphInfo.image.width
        RemainingWidth -= GlyphWidth
        if RemainingWidth < 0 {
            str.write_rune(&StringBuilder, '\n')
            RemainingWidth = FieldWidth - GlyphWidth
            RemainingLines -= 1
        }

        str.write_rune(&StringBuilder, Rune)
    }

    Field.Text = str.to_string(StringBuilder)
}

AddNewNote :: proc(Collection: ^note_collection, Coord1, Coord2: rl.Vector2, Color: rl.Color) {
    if Coord1.x == Coord2.x || Coord1.y == Coord2.y {
        return // NOTE(ingar): Add error?
    }

    LeftX := Coord1.x if Coord1.x < Coord2.x else Coord2.x
    RightX := Coord1.x if Coord1.x > Coord2.x else Coord2.x
    TopY := Coord1.y if Coord1.y < Coord2.y else Coord2.y
    BottomY := Coord1.y if Coord1.y > Coord2.y else Coord2.y

    Width := RightX - LeftX
    Height := BottomY - TopY

    TextField := text_field{}
    TextField.Rect = {LeftX + 5, TopY + 5, Width - 10, Height - 10}
    TextField.Text = "Toodiloo!\nNewline baby!"
    TextField.Font = rl.GetFontDefault()
    TextField.FontSize = 12
    TextField.TextColor = rl.BLACK
    WrapTextFieldString(&TextField)

    NewNote := note{{LeftX, TopY, Width, Height}, Color, TextField, i64(Collection.Count)}
    if Collection.Count < Collection.Size {
        Collection.Notes[Collection.Count] = NewNote
        Collection.Count += 1
    }
}

main :: proc() {
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "StickO-Note")
    rl.SetTargetFPS(144)
    rl.SetWindowMonitor(0)
    WindowConfig := rl.ConfigFlags{.WINDOW_RESIZABLE}
    rl.SetWindowState(WindowConfig)

    SonMemory, Err := make([]u8, 128 * mem.Megabyte)
    defer delete(SonMemory) // NOTE(ingar): Strictly not necessary since it's alive for the entire program
    SonArena: mem.Arena
    mem.arena_init(&SonArena, SonMemory)
    SonAllocator := mem.arena_allocator(&SonArena)
    context.allocator = SonAllocator

    SonState := new(son_state)
    MouseState := new(mouse_state)
    NoteCollection := AllocateNoteCollection(SON_NOTE_COUNT)

    SonState.MouseState = MouseState
    SonState.NoteCollection = NoteCollection
    SonState.Initialized = true

    TextColor := rl.BLACK
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

        if rl.IsMouseButtonPressed(.LEFT) {
            SonState.MouseState.LClicked = true
            SonState.MouseState.PrevLClickPos = MouseWorldPos
        }

        if rl.IsMouseButtonReleased(.LEFT) {
            if SonState.MouseState.LClicked {

                NoteColor := Colors[FrameCount % len(Colors)]
                AddNewNote(
                    SonState.NoteCollection,
                    SonState.MouseState.PrevLClickPos,
                    MouseWorldPos,
                    NoteColor,
                )
                SonState.MouseState.LClicked = false
            }
        }

        // NOTE(ingar): Add button to return to origin?
        if rl.IsMouseButtonDown(.RIGHT) {
            MouseDelta := rl.GetMouseDelta()
            Camera.target -= MouseDelta
        }

        // NOTE(ingar): Cap zoom?
        Camera.zoom += rl.GetMouseWheelMove() * 0.15

        if FrameCount % 144 == 0 {
            fmt.println(
                "Mouse world pos:",
                MouseWorldPos,
                "\nScreen world pos:",
                CurrentScreenWorldPos,
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
        for &Note, i in SonState.NoteCollection.Notes[:SonState.NoteCollection.Count] {
            MouseIsOverNote := rl.CheckCollisionPointRec(MouseWorldPos, Note.Rect)
            if MouseIsOverNote {
                // TODO(ingar): Highlights all notes under mouse, not just top-most
                Shadow := rl.Rectangle {
                    Note.Rect.x + 5,
                    Note.Rect.y + 5,
                    Note.Rect.width + 5,
                    Note.Rect.height + 5,
                }
                ShadowColor := rl.Color{0, 0, 0, 70}

                rl.DrawRectangleRec(Shadow, ShadowColor)
                rl.DrawRectangleRec(Note.Rect, Note.Color)
                RenderTextField(&Note.TextField)

                if rl.IsKeyPressed(.D) {
                    TopMostNote = i
                }
            } else {
                rl.DrawRectangleRec(Note.Rect, Note.Color)
                RenderTextField(&Note.TextField)
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


        rl.EndMode2D()
        rl.EndDrawing()

        /**********************/
        /*    EO RENDERING    */
        /**********************/

        if TopMostNote >= 0 {
            RemoveNote(SonState.NoteCollection, u64(TopMostNote))
            TopMostNote = -1
        }

        free_all(context.temp_allocator)
        FrameCount += 1
    }

    rl.CloseWindow()
}
