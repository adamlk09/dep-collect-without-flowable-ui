package com.mercure.recouvrement.workflow.application;

import com.deptcollector.shared.tenant.TenantContext;
import com.mercure.recouvrement.workflow.audit.OutboxEventWriter;
import com.mercure.recouvrement.workflow.client.NotificationClient;
import com.mercure.recouvrement.workflow.dto.IncidentDto;
import com.mercure.recouvrement.workflow.dto.JobDto;
import com.mercure.recouvrement.workflow.dto.ProcessHistoryDto;
import com.mercure.recouvrement.workflow.dto.TaskDto;
import org.flowable.engine.HistoryService;
import org.flowable.engine.ManagementService;
import org.flowable.engine.RuntimeService;
import org.flowable.engine.TaskService;
import org.flowable.engine.runtime.Execution;
import org.flowable.job.api.Job;
import org.flowable.task.api.Task;
import org.flowable.variable.api.history.HistoricVariableInstance;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

@Service
public class CollectionWorkflowService {

    private static final Logger log = LoggerFactory.getLogger(CollectionWorkflowService.class);

    private final RuntimeService runtimeService;
    private final TaskService taskService;
    private final HistoryService historyService;
    private final ManagementService managementService;
    private final NotificationClient notificationClient;
    private final OutboxEventWriter outboxEventWriter;

    public CollectionWorkflowService(RuntimeService runtimeService,
                                     TaskService taskService,
                                     HistoryService historyService,
                                     ManagementService managementService,
                                     NotificationClient notificationClient,
                                     OutboxEventWriter outboxEventWriter) {
        this.runtimeService = runtimeService;
        this.taskService = taskService;
        this.historyService = historyService;
        this.managementService = managementService;
        this.notificationClient = notificationClient;
        this.outboxEventWriter = outboxEventWriter;
    }

    public List<TaskDto> getActiveTasks() {
        String tenantId = TenantContext.getRequiredTenantId();
        return taskService.createTaskQuery()
                .processVariableValueEquals("tenantId", tenantId)
                .active()
                .list()
                .stream()
                .map(this::toTaskDto)
                .toList();
    }

    public void assignTask(String taskId, String assignee) {
        TenantContext.getRequiredTenantId();
        taskService.setAssignee(taskId, assignee);
        log.info("Assigned taskId={} assignee={}", taskId, assignee);
    }

    public void completeTask(String taskId, Map<String, Object> variables) {
        String tenantId = TenantContext.getRequiredTenantId();
        Task task = taskService.createTaskQuery().taskId(taskId).singleResult();
        String debtId = task != null ? String.valueOf(taskService.getVariable(taskId, "debtId")) : null;
        taskService.complete(taskId, variables != null ? variables : Map.of());
        log.info("Completed taskId={}", taskId);
        if (debtId != null) {
            outboxEventWriter.write(tenantId, "CollectionCase", debtId, "TaskActionPerformed",
                    Map.of("taskId", taskId, "taskName", task.getName(),
                            "actionType", variables != null ? String.valueOf(variables.getOrDefault("lastActionType", "COMPLETE")) : "COMPLETE"));
        }
    }

    public void formalNoticeAction(String taskId, String notes) {
        TenantContext.getRequiredTenantId();
        Map<String, Object> taskVars = taskService.getVariables(taskId);
        sendActionEmail(taskVars, "formal-notice",
                "Formal Notice - Collection Case " + taskVars.get("debtId"), "AGENT_TRIGGERED");

        Map<String, Object> vars = new HashMap<>();
        vars.put("formalNoticeSentAt", System.currentTimeMillis());
        vars.put("formalNoticeNotes", notes);
        vars.put("lastActionType", "FORMAL_NOTICE");
        taskService.complete(taskId, vars);
        log.info("Formal notice sent and completed taskId={}", taskId);
    }

    public void escalateAction(String taskId, String reason) {
        TenantContext.getRequiredTenantId();
        Map<String, Object> taskVars = taskService.getVariables(taskId);
        Map<String, String> emailVars = new HashMap<>();
        emailVars.put("caseId", String.valueOf(taskVars.get("debtId")));
        emailVars.put("customerName", String.valueOf(taskVars.getOrDefault("customerName", taskVars.get("debtId"))));
        emailVars.put("escalationReason", reason);
        emailVars.put("escalationTarget", " to the senior collection team");
        String tenantId = String.valueOf(taskVars.get("tenantId"));
        String email = (String) taskVars.get("customerEmail");
        if (email != null) {
            notificationClient.sendEmail(tenantId, email,
                    "Collection Case Escalated to Legal", "escalation", emailVars, "AGENT_TRIGGERED");
        }

        Map<String, Object> vars = new HashMap<>();
        vars.put("escalationRequested", true);
        vars.put("escalationReason", reason);
        vars.put("lastActionType", "ESCALATE");
        taskService.complete(taskId, vars);
        log.info("Escalation email sent and completed taskId={}", taskId);
    }

    private void sendActionEmail(Map<String, Object> taskVars, String templateName, String subject, String triggerType) {
        String email = (String) taskVars.get("customerEmail");
        if (email == null) {
            return;
        }
        String tenantId = String.valueOf(taskVars.get("tenantId"));
        Map<String, String> emailVars = Map.of(
                "caseId", String.valueOf(taskVars.get("debtId")),
                "customerName", String.valueOf(taskVars.getOrDefault("customerName", taskVars.get("debtId"))),
                "amount", String.valueOf(taskVars.get("totalExposure")),
                "daysOverdue", String.valueOf(taskVars.get("overdueDays")));
        notificationClient.sendEmail(tenantId, email, subject, templateName, emailVars, triggerType);
    }

    public void correlatePayment(String caseId, Double amount, String paymentDate) {
        TenantContext.getRequiredTenantId();
        List<Execution> waiting = runtimeService.createExecutionQuery()
                .messageEventSubscriptionName("paymentReceivedMessage")
                .list();
        Execution execution = waiting.stream()
                .filter(e -> caseId.equals(runtimeService.getVariable(e.getProcessInstanceId(), "debtId")))
                .findFirst()
                .orElse(null);
        if (execution == null) {
            throw new IllegalStateException("No process instance for caseId " + caseId
                    + " is currently waiting on paymentReceivedMessage");
        }
        Map<String, Object> vars = new HashMap<>();
        vars.put("paymentAmount", amount);
        vars.put("paymentDate", paymentDate);
        vars.put("paymentReceived", true);

        String tenantId = (String) runtimeService.getVariable(execution.getProcessInstanceId(), "tenantId");
        String customerEmail = (String) runtimeService.getVariable(execution.getProcessInstanceId(), "customerEmail");
        if (customerEmail != null) {
            Map<String, String> emailVars = Map.of(
                    "caseId", caseId,
                    "customerName", String.valueOf(runtimeService.getVariable(
                            execution.getProcessInstanceId(), "customerName")),
                    "amount", String.valueOf(amount),
                    "promiseDate", String.valueOf(paymentDate));
            notificationClient.sendEmail(tenantId, customerEmail, "Payment Promise Confirmation - Collection Case " + caseId,
                    "payment-confirmation", emailVars, "AUTOMATIC");
        }

        runtimeService.messageEventReceived("paymentReceivedMessage", execution.getId(), vars);
        log.info("Payment correlated caseId={} amount={} paymentDate={}", caseId, amount, paymentDate);
    }

    private TaskDto toTaskDto(Task t) {
        return new TaskDto(t.getId(), t.getName(), t.getProcessInstanceId(),
                t.getProcessDefinitionId(), t.getAssignee(), t.getCreateTime());
    }

    public List<ProcessHistoryDto> getProcessHistory(String processInstanceId) {
        TenantContext.getRequiredTenantId();
        return historyService.createHistoricActivityInstanceQuery()
                .processInstanceId(processInstanceId)
                .orderByHistoricActivityInstanceStartTime().asc()
                .list()
                .stream()
                .map(h -> new ProcessHistoryDto(h.getActivityId(), h.getActivityName(),
                        h.getActivityType(), h.getStartTime(), h.getEndTime(), h.getDurationInMillis()))
                .toList();
    }

    public void setVariables(String processInstanceId, Map<String, Object> variables) {
        TenantContext.getRequiredTenantId();
        runtimeService.setVariables(processInstanceId, variables != null ? variables : Map.of());
        log.info("Variables set pid={} names={}", processInstanceId,
                variables != null ? variables.keySet() : Map.of().keySet());
    }

    public Map<String, Object> getVariables(String processInstanceId) {
        TenantContext.getRequiredTenantId();
        return historyService.createHistoricVariableInstanceQuery()
                .processInstanceId(processInstanceId)
                .list()
                .stream()
                .collect(Collectors.toMap(
                        HistoricVariableInstance::getVariableName,
                        HistoricVariableInstance::getValue));
    }

    public List<IncidentDto> getIncidents(String processInstanceId) {
        TenantContext.getRequiredTenantId();
        return managementService.createJobQuery()
                .processInstanceId(processInstanceId)
                .withException()
                .list()
                .stream()
                .map(j -> new IncidentDto(j.getId(), j.getProcessInstanceId(), j.getElementId(),
                        "failedJob", j.getExceptionMessage(), j.getDuedate()))
                .toList();
    }

    public List<JobDto> getDeadLetterJobs(String processInstanceId) {
        TenantContext.getRequiredTenantId();
        return managementService.createDeadLetterJobQuery()
                .processInstanceId(processInstanceId)
                .list()
                .stream()
                .map(j -> new JobDto(j.getId(), j.getProcessInstanceId(), j.getElementId(),
                        j.getElementName(), j.getDuedate(), j.getRetries(), j.getExceptionMessage()))
                .toList();
    }

    public void retryDeadLetterJob(String jobId) {
        TenantContext.getRequiredTenantId();
        managementService.moveDeadLetterJobToExecutableJob(jobId, 3);
        log.info("Dead-letter job requeued jobId={}", jobId);
    }

    public List<JobDto> getTimers(String processInstanceId) {
        TenantContext.getRequiredTenantId();
        return managementService.createTimerJobQuery()
                .processInstanceId(processInstanceId)
                .list()
                .stream()
                .map(j -> new JobDto(j.getId(), j.getProcessInstanceId(), j.getElementId(),
                        j.getElementName(), j.getDuedate(), j.getRetries(), j.getExceptionMessage()))
                .toList();
    }

    public void triggerTimer(String timerId) {
        TenantContext.getRequiredTenantId();
        Job executableJob = managementService.moveTimerToExecutableJob(timerId);
        managementService.executeJob(executableJob.getId());
        log.info("Timer triggered timerId={}", timerId);
    }
}
