package main

import (
	"log"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/item-service/internal/bootstrap"
)

func main() {
	if err := bootstrap.Run(); err != nil {
		log.Fatalf("item-service failed to start: %v", err)
	}
}
