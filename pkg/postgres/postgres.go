package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const defaultConnectTimeout = 10 * time.Second

// PoolConfig holds connection pool settings for pgxpool. All fields are
// optional: zero values let pgxpool use its own defaults.
type PoolConfig struct {
	// MaxConns is the maximum number of connections in the pool.
	MaxConns int32
	// MinConns is the minimum number of idle connections kept in the pool.
	MinConns int32
	// MaxConnLifetime is the maximum lifetime of a connection. Connections
	// older than this are closed and replaced. Set to 0 to disable.
	MaxConnLifetime time.Duration
	// MaxConnIdleTime is the maximum time a connection can remain idle
	// before being closed. Set to 0 to disable.
	MaxConnIdleTime time.Duration
	// PingTimeout is the timeout for the initial ping after pool creation.
	// If 0, defaultConnectTimeout is used.
	PingTimeout time.Duration
}

// Connect creates a pgxpool connection pool. If poolCfg is non-nil, the pool
// settings are applied; otherwise pgxpool defaults are used. The function
// pings the database to verify connectivity before returning.
func Connect(ctx context.Context, databaseURL string, poolCfg *PoolConfig) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse postgres config: %w", err)
	}

	if poolCfg != nil {
		cfg.MaxConns = poolCfg.MaxConns
		cfg.MinConns = poolCfg.MinConns
		cfg.MaxConnLifetime = poolCfg.MaxConnLifetime
		cfg.MaxConnIdleTime = poolCfg.MaxConnIdleTime
	}

	pingTimeout := defaultConnectTimeout
	if poolCfg != nil && poolCfg.PingTimeout > 0 {
		pingTimeout = poolCfg.PingTimeout
	}

	connectCtx := ctx
	cancel := func() {}
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		connectCtx, cancel = context.WithTimeout(ctx, pingTimeout)
	}
	defer cancel()

	pool, err := pgxpool.NewWithConfig(connectCtx, cfg)
	if err != nil {
		return nil, fmt.Errorf("open postgres pool: %w", err)
	}

	if err := pool.Ping(connectCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return pool, nil
}
