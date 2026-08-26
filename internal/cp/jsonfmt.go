package cp

import (
	"encoding/json"
	"strings"
)

// marshalPythonJSON matches Python json.dumps default spacing (", " and ": ").
func marshalPythonJSON(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return pythonJSONSpacing(string(b)), nil
}

func pythonJSONSpacing(s string) string {
	var out strings.Builder
	inString := false
	escape := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if escape {
			out.WriteByte(c)
			escape = false
			continue
		}
		if c == '\\' && inString {
			escape = true
			out.WriteByte(c)
			continue
		}
		if c == '"' {
			inString = !inString
			out.WriteByte(c)
			continue
		}
		if !inString {
			if c == ':' {
				out.WriteString(": ")
				continue
			}
			if c == ',' {
				out.WriteString(", ")
				continue
			}
		}
		out.WriteByte(c)
	}
	return out.String()
}
