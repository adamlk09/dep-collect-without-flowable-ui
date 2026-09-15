package com.mercure.recouvrement.workflow.client;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

@Component
public class SegmentationClient {

    private final RestClient restClient;

    public SegmentationClient(RestClient.Builder builder,
                              @Value("${app.segmentation-service.url:http://localhost:8092}") String baseUrl) {
        this.restClient = builder.baseUrl(baseUrl).build();
    }

    public StagingDecisionResponse stageRecovery(String tenantId, String correlationId,
                                                 StagingDecisionRequest request) {
        return restClient.post()
                .uri("/api/v1/segmentation/staging/execute")
                .headers(headers -> {
                    headers.set("X-Tenant-Id", tenantId);
                    if (correlationId != null && !correlationId.isBlank()) {
                        headers.set("X-Correlation-Id", correlationId);
                    }
                })
                .contentType(MediaType.APPLICATION_JSON)
                .body(request)
                .retrieve()
                .body(StagingDecisionResponse.class);
    }
}
