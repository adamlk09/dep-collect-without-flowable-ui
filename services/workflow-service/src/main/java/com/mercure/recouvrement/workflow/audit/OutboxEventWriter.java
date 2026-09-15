package com.mercure.recouvrement.workflow.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;

@Component
public class OutboxEventWriter {

    private static final Logger log = LoggerFactory.getLogger(OutboxEventWriter.class);

    private final JdbcTemplate jdbcTemplate;
    private final ObjectMapper objectMapper;

    public OutboxEventWriter(JdbcTemplate jdbcTemplate, ObjectMapper objectMapper) {
        this.jdbcTemplate = jdbcTemplate;
        this.objectMapper = objectMapper;
    }

    public void write(String tenantId, String aggregateType, String aggregateId, String eventType,
                      Map<String, Object> payload) {
        try {
            String json = objectMapper.writeValueAsString(payload);
            jdbcTemplate.update(
                    "INSERT INTO outbox_event (id, tenant_id, aggregate_type, aggregate_id, event_type, payload, occurred_at) "
                            + "VALUES (?, ?, ?, ?, ?, ?::jsonb, ?)",
                    UUID.randomUUID(), tenantId, aggregateType, aggregateId, eventType, json,
                    Timestamp.from(Instant.now()));
        } catch (Exception e) {
            log.warn("Failed to write audit event type={} aggregateId={}: {}", eventType, aggregateId, e.getMessage());
        }
    }
}
