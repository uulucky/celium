package main

import "strings"

// FullTrustProcessLauncher prepends the calling package-relative app ID.
// It is launch metadata, not a CLI command or an authorization credential.
func activationArgs(args []string) []string {
	if len(args) >= 2 && strings.EqualFold(args[0], "/InvokerPRAID:") && args[1] == "Desktop" {
		args = args[2:]
	}
	if len(args) == 1 && args[0] == "--desktop" {
		return nil
	}
	return args
}
