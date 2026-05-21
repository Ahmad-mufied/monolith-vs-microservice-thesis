package observability

import (
	"os"
	"strings"

	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	"github.com/DataDog/dd-trace-go/v2/profiler"
)

func ServiceName(fallback string) string {
	if value := strings.TrimSpace(os.Getenv("DD_SERVICE")); value != "" {
		return value
	}
	return fallback
}

func Start(defaultService string) (func(), error) {
	if !enabled("DATADOG_ENABLED") && !enabled("DD_TRACE_ENABLED") {
		return func() {}, nil
	}

	service := ServiceName(defaultService)
	options := []tracer.StartOption{}
	if service != "" {
		options = append(options, tracer.WithService(service))
	}
	if err := tracer.Start(options...); err != nil {
		return nil, err
	}

	profilerStarted := false
	if enabled("DATADOG_PROFILING_ENABLED") || enabled("DD_PROFILING_ENABLED") {
		if err := profiler.Start(profiler.WithService(service)); err != nil {
			tracer.Stop()
			return nil, err
		}
		profilerStarted = true
	}

	return func() {
		if profilerStarted {
			profiler.Stop()
		}
		tracer.Stop()
	}, nil
}

func enabled(key string) bool {
	return strings.EqualFold(os.Getenv(key), "true")
}
