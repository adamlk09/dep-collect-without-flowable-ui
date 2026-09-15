package com.deptcollector.notification.api.dto;

import jakarta.validation.constraints.NotBlank;

import java.util.Map;

public record SendEmailRequest(
        @NotBlank String to,
        @NotBlank String subject,
        @NotBlank String templateName,
        Map<String, String> variables,
        String triggerType
) {}
