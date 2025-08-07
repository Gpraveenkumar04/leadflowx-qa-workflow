package main


import (
	"context"
	"log"
	"os"
	"encoding/json"
	"github.com/segmentio/kafka-go"
	"github.com/your-org/verifier/internal/validate"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"net/http"
)


func main() {
	// Prometheus metrics
	verifiedCounter := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "verifier_verified_total",
		Help: "Total number of verified leads",
	})
	invalidCounter := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "verifier_invalid_total",
		Help: "Total number of invalid leads",
	})
	prometheus.MustRegister(verifiedCounter, invalidCounter)

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(":9090", nil)
	}()

	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers: []string{getEnv("KAFKA_BROKER", "kafka:9092")},
		Topic:   getEnv("KAFKA_RAW_TOPIC", "lead.raw"),
		GroupID: getEnv("KAFKA_GROUP_ID", "verifier-group"),
	})
	writer := kafka.NewWriter(kafka.WriterConfig{
		Brokers: []string{getEnv("KAFKA_BROKER", "kafka:9092")},
		Topic:   getEnv("KAFKA_VERIFIED_TOPIC", "lead.verified"),
	})
	dlqWriter := kafka.NewWriter(kafka.WriterConfig{
		Brokers: []string{getEnv("KAFKA_BROKER", "kafka:9092")},
		Topic:   "lead.dlq",
	})
	defer reader.Close()
	defer writer.Close()
	defer dlqWriter.Close()

	for {
		msg, err := reader.ReadMessage(context.Background())
		if err != nil {
			log.Printf("Error reading message: %v", err)
			continue
		}

		var lead map[string]interface{}
		json.Unmarshal(msg.Value, &lead)
		correlationId := ""
		if len(msg.Headers) > 0 {
			h := msg.Headers[0]
			if h.Key == "correlationId" {
				correlationId = string(h.Value)
			}
		}
		verified := validate.Email(lead["email"].(string))
		if verified {
			if err := writer.WriteMessages(context.Background(), msg); err != nil {
				log.Printf("Error writing message: %v", err)
			} else {
				verifiedCounter.Inc()
				log.Printf("[TRACE] Verified lead: %v, correlationId: %s", lead, correlationId)
			}
		} else {
			invalidCounter.Inc()
			log.Printf("[TRACE] Invalid lead: %v, correlationId: %s", lead, correlationId)
			// Publish to DLQ
			if err := dlqWriter.WriteMessages(context.Background(), msg); err != nil {
				log.Printf("Error writing to DLQ: %v", err)
			}
		}
	}
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
