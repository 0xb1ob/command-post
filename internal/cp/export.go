package cp

// Exported wrappers for cmd/cp.

func PrintUsageMain() { printUsage() }
func HandleErr(err error) { handleErr(err) }
func DieUsage(format string, args ...any) { dieUsage(format, args...) }
