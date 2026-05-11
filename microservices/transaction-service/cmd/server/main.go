package main

import (
	"log"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/microservices/transaction-service/internal/bootstrap"
)

func main() {
	if err := bootstrap.Run(); err != nil {
		log.Fatalf("transaction-service failed to start: %v", err)
	}
}
