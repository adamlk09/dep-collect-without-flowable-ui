package com.mercure.recouvrement.workflow.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;

public record StartBankingRecoveryRequest(
        @NotBlank String debtId,
        @NotBlank String customerId,
        String clientSegment,
        @NotNull @PositiveOrZero Integer overdueDays,
        @NotNull @PositiveOrZero Double totalExposure,
        String phoneNumber,
        String address,
        String customerEmail,
        String customerName
) {}
