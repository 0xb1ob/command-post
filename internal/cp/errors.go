package cp

import (
	"fmt"
	"os"
)

type exitError struct {
	code int
	msg  string
}

func (e *exitError) Error() string { return e.msg }

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[cp] error: "+format+"\n", args...)
	os.Exit(1)
}

func dieUsage(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[cp] error: "+format+"\n", args...)
	os.Exit(2)
}

func usageError(format string, args ...any) error {
	return &exitError{code: 2, msg: fmt.Sprintf(format, args...)}
}

func failError(format string, args ...any) error {
	return &exitError{code: 1, msg: fmt.Sprintf(format, args...)}
}

func log(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[cp] "+format+"\n", args...)
}

func handleErr(err error) {
	if err == nil {
		return
	}
	if ee, ok := err.(*exitError); ok {
		fmt.Fprintf(os.Stderr, "[cp] error: %s\n", ee.msg)
		os.Exit(ee.code)
	}
	fmt.Fprintf(os.Stderr, "[cp] error: %s\n", err)
	os.Exit(1)
}

func gateExit(verdict string) {
	switch verdict {
	case "pass":
		os.Exit(0)
	case "revise":
		os.Exit(10)
	case "escalate":
		os.Exit(20)
	default:
		die("internal: bad verdict %s", verdict)
	}
}
