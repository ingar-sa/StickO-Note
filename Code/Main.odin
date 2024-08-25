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
	// NOTE(ingar): Make dynamic? 
	// Currently note deletion does not compact the array, it just keeps going
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
	DrawPosX := i32(Field.Rect.x)
	DrawPosY := i32(Field.Rect.y)
	rl.DrawText(CString, DrawPosX, DrawPosY, Field.FontSize, Field.TextColor)
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

	//TextField := new(text_field)
	TextField := text_field{}
	TextField.Rect = {LeftX + 5, TopY + 5, Width - 10, Height - 10}
	TextField.Text = "Toodiloo!"
	TextField.FontSize = 12
	TextField.TextColor = rl.BLACK

	NewNote := note{{LeftX, TopY, Width, Height}, Color, TextField, i64(Collection.Count)}
	if Collection.Count < Collection.Size {
		Collection.Notes[Collection.Count] = NewNote
		Collection.Count += 1
	}
}

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "StickO-Note")
	rl.SetTargetFPS(144)

	SonMemory, Err := make([]u8, 128 * mem.Megabyte)
	defer delete(SonMemory)
	fmt.println("Err ", Err)

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

	TextColor: rl.Color = rl.BLACK

	Colors := []rl.Color {
		rl.LIGHTGRAY,
		rl.YELLOW,
		rl.PINK,
		rl.VIOLET,
		rl.MAROON,
		rl.BEIGE,
		rl.MAGENTA,
	}
	i := 0
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()

		rl.ClearBackground(rl.DARKGRAY)

		if rl.IsMouseButtonPressed(.LEFT) {
			SonState.MouseState.LClicked = true
			SonState.MouseState.PrevLClickPos = rl.GetMousePosition()
		}
		if rl.IsMouseButtonPressed(.RIGHT) {
			SonState.MouseState.RClicked = true
			SonState.MouseState.PrevRClickPos = rl.GetMousePosition()
		}

		if rl.IsMouseButtonReleased(.LEFT) {
			if SonState.MouseState.LClicked {
				MousePos := rl.GetMousePosition()
				NoteColor := Colors[i % len(Colors)]
				AddNewNote(
					SonState.NoteCollection,
					SonState.MouseState.PrevLClickPos,
					MousePos,
					NoteColor,
				)
				SonState.MouseState.LClicked = false
				i += 1
			}
		}

		RClickPos := rl.Vector2{}
		if rl.IsMouseButtonReleased(.RIGHT) {
			RClickPos = rl.GetMousePosition()

			// NOTE(ingar): Refactor right click logic
			SonState.MouseState.RClicked = true
		}

		rl.DrawText("Hellope!", WINDOW_WIDTH / 2 - 50, WINDOW_HEIGHT / 2 - 50, 20, TextColor)

		ToDelete := -1
		for &Note, i in SonState.NoteCollection.Notes[:SonState.NoteCollection.Count] {
			RClickOnNote := rl.CheckCollisionPointRec(RClickPos, Note.Rect)
			if RClickOnNote {
				ToDelete = i
			}
			rl.DrawRectangleRec(Note.Rect, Note.Color)
			RenderTextField(&Note.TextField)
		}

		if ToDelete >= 0 {
			RemoveNote(SonState.NoteCollection, u64(ToDelete))
		}

		free_all(context.temp_allocator)
		rl.EndDrawing()
	}

	rl.CloseWindow()
}
