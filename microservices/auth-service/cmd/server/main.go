package main

import (
	"log"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/auth-service/internal/bootstrap"
)

func main() {
	if err := bootstrap.Run(); err != nil {
		log.Fatalf("auth-service exited with error: %v", err)
	}
}
