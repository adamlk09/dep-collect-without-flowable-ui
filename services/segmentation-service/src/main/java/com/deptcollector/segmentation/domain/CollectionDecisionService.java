package com.deptcollector.segmentation.domain;

import org.flowable.dmn.api.DmnDecisionService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.Map;

@Service
public class CollectionDecisionService {

    private static final Logger log = LoggerFactory.getLogger(CollectionDecisionService.class);

    private final DmnDecisionService dmnDecisionService;

    public CollectionDecisionService(DmnDecisionService dmnDecisionService) {
        this.dmnDecisionService = dmnDecisionService;
    }

    public Result evaluate(Integer overdueDays, Double totalExposure, String customerType) {
        Map<String, Object> staging = dmnDecisionService.createExecuteDecisionBuilder()
                .decisionKey("collectionStagingDecision")
                .variable("overdueDays", overdueDays)
                .variable("totalExposure", totalExposure)
                .executeWithSingleResult();

        String ifrsStage = staging != null ? (String) staging.get("ifrsStage") : "STAGE_2";
        String collectionPhase = staging != null ? (String) staging.get("collectionPhase") : "COMMERCIAL";

        Map<String, Object> priorityResult = dmnDecisionService.createExecuteDecisionBuilder()
                .decisionKey("collectionPriorityDecision")
                .variable("collectionPhase", collectionPhase)
                .executeWithSingleResult();

        String priority = priorityResult != null ? (String) priorityResult.get("priority") : "LOW";
        Number priorityScore = priorityResult != null ? (Number) priorityResult.get("priorityScore") : 10;

        Map<String, Object> actionResult = dmnDecisionService.createExecuteDecisionBuilder()
                .decisionKey("collectionActionDecision")
                .variable("priority", priority)
                .variable("collectionPhase", collectionPhase)
                .executeWithSingleResult();

        String recommendedAction = actionResult != null ? (String) actionResult.get("recommendedAction") : "SMS_EMAIL";
        String collectorLevel = actionResult != null ? (String) actionResult.get("collectorLevel") : "COLLECTOR_LEVEL_1";

        Map<String, Object> segmentationResult = dmnDecisionService.createExecuteDecisionBuilder()
                .decisionKey("customerSegmentationDecision")
                .variable("customerType", customerType)
                .variable("totalExposure", totalExposure)
                .executeWithSingleResult();

        String customerSegment = segmentationResult != null
                ? (String) segmentationResult.get("customerSegment") : "PARTICULIER";

        log.info("Collection decision chain: overdueDays={} totalExposure={} customerType={} "
                        + "-> ifrsStage={} collectionPhase={} priority={} priorityScore={} "
                        + "recommendedAction={} collectorLevel={} customerSegment={}",
                overdueDays, totalExposure, customerType, ifrsStage, collectionPhase, priority,
                priorityScore, recommendedAction, collectorLevel, customerSegment);

        return new Result(ifrsStage, collectionPhase, priority, priorityScore.intValue(),
                recommendedAction, collectorLevel, customerSegment);
    }

    public record Result(
            String ifrsStage,
            String collectionPhase,
            String priority,
            int priorityScore,
            String recommendedAction,
            String collectorLevel,
            String customerSegment
    ) {}
}
