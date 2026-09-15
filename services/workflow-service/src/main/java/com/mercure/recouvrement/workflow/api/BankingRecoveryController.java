package com.mercure.recouvrement.workflow.api;

import com.mercure.recouvrement.workflow.application.BankingRecoveryWorkflowService;
import com.mercure.recouvrement.workflow.dto.StartBankingRecoveryRequest;
import com.mercure.recouvrement.workflow.dto.StartBankingRecoveryResponse;
import com.mercure.recouvrement.workflow.dto.StartProcessResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/workflows/banking-recovery")
public class BankingRecoveryController {

    private final BankingRecoveryWorkflowService workflowService;

    public BankingRecoveryController(BankingRecoveryWorkflowService workflowService) {
        this.workflowService = workflowService;
    }

    @PostMapping("/start")
    public ResponseEntity<StartBankingRecoveryResponse> startRecovery(
            @Valid @RequestBody StartBankingRecoveryRequest request) {
        StartBankingRecoveryResponse response = workflowService.startRecovery(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @PostMapping("/processes")
    public ResponseEntity<StartProcessResponse> startProcess(
            @Valid @RequestBody StartBankingRecoveryRequest request) {
        StartProcessResponse response = workflowService.startProcess(request);
        return ResponseEntity
                .status(response.created() ? HttpStatus.CREATED : HttpStatus.OK)
                .body(response);
    }
}
