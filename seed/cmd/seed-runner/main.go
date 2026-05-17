package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/Ahmad-mufied/monolith-vs-microservice-thesis/seed/internal/seed"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("usage: seed-runner <reset-monolith-data|seed-monolith-data|prepare-monolith-enrichment-data|reset-microservices-data|seed-microservices-data|prepare-microservices-enrichment-data> [flags]")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	switch os.Args[1] {
	case "reset-monolith-data":
		resetMonolithData(ctx, os.Args[2:])
	case "seed-monolith-data":
		seedMonolithData(ctx, os.Args[2:])
	case "prepare-monolith-enrichment-data":
		prepareMonolithEnrichmentData(ctx, os.Args[2:])
	case "reset-microservices-data":
		resetMicroservicesData(ctx, os.Args[2:])
	case "seed-microservices-data":
		seedMicroservicesData(ctx, os.Args[2:])
	case "prepare-microservices-enrichment-data":
		prepareMicroservicesEnrichmentData(ctx, os.Args[2:])
	default:
		log.Fatalf("unknown command %q", os.Args[1])
	}
}

func resetMonolithData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("reset-monolith-data", flag.ExitOnError)
	cfg := seed.MonolithConfig{}
	fs.StringVar(&cfg.DatabaseURL, "database-url", "", "monolith database url")
	fs.Parse(args)

	if err := seed.ResetMonolithData(ctx, cfg); err != nil {
		log.Fatalf("reset monolith data: %v", err)
	}
}

func seedMonolithData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("seed-monolith-data", flag.ExitOnError)
	cfg := seed.MonolithConfig{}
	dataset := fs.String("dataset", "smoke", "dataset mode: smoke or benchmark")
	fs.StringVar(&cfg.DatabaseURL, "database-url", "", "monolith database url")
	fs.Parse(args)

	if err := seed.SeedMonolithData(ctx, cfg, *dataset); err != nil {
		log.Fatalf("seed monolith data (%s): %v", *dataset, err)
	}

	fmt.Printf("seeded monolith dataset=%s\n", *dataset)
}

func prepareMonolithEnrichmentData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("prepare-monolith-enrichment-data", flag.ExitOnError)
	cfg := seed.MonolithConfig{}
	dataset := fs.String("dataset", "smoke", "dataset mode: smoke or benchmark")
	fs.StringVar(&cfg.DatabaseURL, "database-url", "", "monolith database url")
	fs.Parse(args)

	if err := seed.PrepareMonolithEnrichmentData(ctx, cfg, *dataset); err != nil {
		log.Fatalf("prepare monolith enrichment data (%s): %v", *dataset, err)
	}

	fmt.Printf("prepared monolith enrichment dataset=%s\n", *dataset)
}

func resetMicroservicesData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("reset-microservices-data", flag.ExitOnError)
	cfg := seed.MicroservicesConfig{}
	fs.StringVar(&cfg.AuthDatabaseURL, "auth-database-url", "", "auth database url")
	fs.StringVar(&cfg.ItemDatabaseURL, "item-database-url", "", "item database url")
	fs.StringVar(&cfg.TransactionDatabaseURL, "transaction-database-url", "", "transaction database url")
	fs.Parse(args)

	if err := seed.ResetMicroservicesData(ctx, cfg); err != nil {
		log.Fatalf("reset microservices data: %v", err)
	}
}

func seedMicroservicesData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("seed-microservices-data", flag.ExitOnError)
	cfg := seed.MicroservicesConfig{}
	dataset := fs.String("dataset", "smoke", "dataset mode: smoke or benchmark")
	fs.StringVar(&cfg.AuthDatabaseURL, "auth-database-url", "", "auth database url")
	fs.StringVar(&cfg.ItemDatabaseURL, "item-database-url", "", "item database url")
	fs.StringVar(&cfg.TransactionDatabaseURL, "transaction-database-url", "", "transaction database url")
	fs.Parse(args)

	if err := seed.SeedMicroservicesData(ctx, cfg, *dataset); err != nil {
		log.Fatalf("seed microservices data (%s): %v", *dataset, err)
	}

	fmt.Printf("seeded microservices dataset=%s\n", *dataset)
}

func prepareMicroservicesEnrichmentData(ctx context.Context, args []string) {
	fs := flag.NewFlagSet("prepare-microservices-enrichment-data", flag.ExitOnError)
	cfg := seed.MicroservicesConfig{}
	dataset := fs.String("dataset", "smoke", "dataset mode: smoke or benchmark")
	fs.StringVar(&cfg.AuthDatabaseURL, "auth-database-url", "", "auth database url")
	fs.StringVar(&cfg.ItemDatabaseURL, "item-database-url", "", "item database url")
	fs.StringVar(&cfg.TransactionDatabaseURL, "transaction-database-url", "", "transaction database url")
	fs.Parse(args)

	if err := seed.PrepareMicroservicesEnrichmentData(ctx, cfg, *dataset); err != nil {
		log.Fatalf("prepare microservices enrichment data (%s): %v", *dataset, err)
	}

	fmt.Printf("prepared microservices enrichment dataset=%s\n", *dataset)
}
