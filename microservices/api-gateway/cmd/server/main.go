package main

import (
	"log"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/api-gateway/internal/bootstrap"
)

// main is the program entry point. It calls bootstrap.Run and terminates the process with a fatal log if Run returns an error.
func main() {
	if err := bootstrap.Run(); err != nil {
		log.Fatal(err)
	}
}
