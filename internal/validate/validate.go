package validate

import (
	"regexp"
)

// Email validates the email address format
func Email(email string) bool {
	// Simple regex for demonstration; use a more robust one in production
	re := regexp.MustCompile(`^[a-zA-Z0-9._%%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)
	return re.MatchString(email)
}
