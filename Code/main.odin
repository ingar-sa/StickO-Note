package SON

import "core:fmt"
import rl "vendor:raylib"

WINDOW_WIDTH :: 960
WINDOW_HEIGHT :: 540

main :: proc() {
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "StickO-Note")
	rl.SetTargetFPS(60)

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()

		rl.ClearBackground(rl.RAYWHITE)
		rl.DrawText("Hellope!", WINDOW_WIDTH / 2 - 50, WINDOW_HEIGHT / 2 - 50, 20, rl.LIGHTGRAY)

		rl.EndDrawing()
	}

	rl.CloseWindow()
}
