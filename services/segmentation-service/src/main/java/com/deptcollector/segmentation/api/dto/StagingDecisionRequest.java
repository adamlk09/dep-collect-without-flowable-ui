package com.deptcollector.segmentation.api.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

public record StagingDecisionRequest(
        @NotBlank String debtId,
        @NotNull Integer overdueDays,
        @NotNull Double totalExposure,
        String customerType
) {}
