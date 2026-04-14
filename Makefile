.PHONY: run build

run:
	go run ./cmd/notes-app

build:
	go build -o notes-app ./cmd/notes-app
