package llm

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// 回归：某些网关（如 developer.amd.com.cn radeon 代理）不发任何 *.delta 事件，
// 只发 output_item.added 且自带完整 arguments。此前参数被丢弃导致工具调用全部
// 以空 {} 落地。修复后 added/done 携带完整 arguments 时必须还原完整工具入参。
func TestResponsesGatewayNoDeltaEvents(t *testing.T) {
	stream := "event: response.created\n" +
		"data: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}\n\n" +
		"event: response.output_item.added\n" +
		"data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"add_intent\",\"arguments\":\"{\\\"intents\\\":[{\\\"summary\\\":\\\"hi\\\"}]}\",\"status\":\"completed\"}}\n\n" +
		"event: response.completed\n" +
		"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}}\n\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/event-stream")
		w.Write([]byte(stream))
	}))
	defer srv.Close()
	p, err := NewProvider(Config{Format: FormatOpenAIResponses, BaseURL: srv.URL, APIKey: "k", Model: "m"})
	if err != nil {
		t.Fatal(err)
	}
	msg := collect(t, p, CompletionRequest{Messages: []Message{UserText("go")}})
	if len(msg.Content) != 1 || msg.Content[0].Type != BlockToolUse {
		t.Fatalf("want one tool_use block, got %+v", msg.Content)
	}
	b := msg.Content[0]
	if b.Name != "add_intent" || b.ID != "call_1" {
		t.Fatalf("bad tool identity: %s %s", b.Name, b.ID)
	}
	if string(b.Input) != "{\"intents\":[{\"summary\":\"hi\"}]}" {
		t.Fatalf("arguments lost, got: %s", string(b.Input))
	}
}