package com.mercure.recouvrement.workflow.delegate;

import org.flowable.engine.delegate.DelegateExecution;
import org.flowable.engine.delegate.JavaDelegate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

@Component("sendReminderDelegate")
public class SendReminderDelegate implements JavaDelegate {

    private static final Logger log = LoggerFactory.getLogger(SendReminderDelegate.class);

    @Override
    public void execute(DelegateExecution execution) {
        String debtId = (String) execution.getVariable("debtId");
        execution.setVariable("reminderSentAt", System.currentTimeMillis());
        log.info("SLA reminder sent pid={} debtId={} — assignToAgent still open",
                execution.getProcessInstanceId(), debtId);
    }
}
