package provider

import (
	"testing"
)

func TestProvider(t *testing.T) {
	p := New("dev")()
	if p == nil {
		t.Fatal("expected provider to not be nil")
	}
}
