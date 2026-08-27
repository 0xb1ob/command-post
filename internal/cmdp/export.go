package cmdp

// Exported wrappers for cmd/cmdp.

func PrintUsageMain() { printUsage() }
func HandleErr(err error) { handleErr(err) }
func DieUsage(format string, args ...any) { dieUsage(format, args...) }
