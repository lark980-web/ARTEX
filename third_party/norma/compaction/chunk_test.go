package compaction

import (
	"context"
	"strings"
	"testing"

	"github.com/Autumn-27/norma/llm"
)

// oversizedHead builds an 8 MiB working head out of alternating user/assistant
// rounds: past the gateway body limit, this is the shape that made AutoCompact
// 413 itself, disable after 3 failures, and then ship the whole body.
func oversizedHead(rounds, eachChars int) []llm.Message {
	var msgs []llm.Message
	for i := 0; i < rounds; i++ {
		msgs = append(msgs, llm.UserText(strings.Repeat("x", eachChars)))
		msgs = append(msgs, asstText("step"))
	}
	return msgs
}

func TestSummarizeInChunksKeepsEveryRequestUnderBudget(t *testing.T) {
	head := oversizedHead(8, 1<<20) // ~8 MiB
	if historyChars(head) <= summarizeChunkChars {
		t.Fatalf("head = %d chars, want > %d so the chunk path is exercised",
			historyChars(head), summarizeChunkChars)
	}

	p := &captureProvider{reply: "<summary>ok</summary>"}
	sum := ProviderSummarizer(p, 8000, false)
	summary, err := sum(context.Background(), head)
	if err != nil {
		t.Fatalf("summarize oversized head: %v", err)
	}
	if summary == "" {
		t.Fatal("want a non-empty summary")
	}
	if len(summary) > summarizeChunkChars {
		t.Fatalf("folded summary = %d chars, still over the %d budget",
			len(summary), summarizeChunkChars)
	}
	if len(p.reqs) < 3 {
		t.Fatalf("want chunked summarization (>=3 provider calls), got %d", len(p.reqs))
	}
	for i, req := range p.reqs {
		if n := historyChars(req.Messages); n > summarizeChunkChars {
			t.Errorf("provider request %d = %d chars, exceeds the %d budget — the gateway would 413 it",
				i, n, summarizeChunkChars)
		}
	}
}

func TestSummarizeInChunksNeedsMultipleRounds(t *testing.T) {
	// A head made of one API round cannot be split; hand it back untouched so the
	// caller's overflow-truncation path owns it.
	head := []llm.Message{llm.UserText(strings.Repeat("x", summarizeChunkChars*2))}
	out, err := summarizeInChunks(context.Background(), head,
		func(context.Context, []llm.Message) (string, error) { return "unused", nil })
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(out) != 1 || out[0].Content[0].Text != head[0].Content[0].Text {
		t.Fatal("single-round head must be returned unchanged")
	}
}

func TestSummarizeInChunksPropagatesFailure(t *testing.T) {
	head := oversizedHead(6, 1<<20)
	_, err := summarizeInChunks(context.Background(), head,
		func(context.Context, []llm.Message) (string, error) { return "", errBoom })
	if err == nil {
		t.Fatal("want the failing chunk's error to surface")
	}
}

var errBoom = chunkTestError("boom")

type chunkTestError string

func (e chunkTestError) Error() string { return string(e) }
