package com.tudou.miaosha.consumer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.tudou.miaosha.model.OrderMessage;
import com.tudou.miaosha.service.OrderWriter;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.stereotype.Component;

@Component
public class OrderConsumer {

    private static final Logger log = LoggerFactory.getLogger(OrderConsumer.class);

    private final ObjectMapper om;
    private final OrderWriter writer;

    public OrderConsumer(ObjectMapper om, OrderWriter writer) {
        this.om = om;
        this.writer = writer;
    }

    /**
     * 手动 ack：落库成功才提交位点。
     *
     * 三种结局：
     *   成功        → ack，继续下一条
     *   订单号重复  → 说明已经落过库（至少一次投递），ack 掉，实现幂等
     *   其他异常    → 不 ack，抛出，让 Kafka 重新投递
     */
    @KafkaListener(topics = "${miaosha.order-topic}", groupId = "miaosha-order-consumer")
    public void onMessage(ConsumerRecord<String, String> record, Acknowledgment ack) {
        OrderMessage m;
        try {
            m = om.readValue(record.value(), OrderMessage.class);
        } catch (Exception e) {
            // 消息体坏了，重试也没用 → ack 掉，别堵住队列
            log.error("消息解析失败，丢弃: {}", record.value(), e);
            ack.acknowledge();
            return;
        }

        try {
            boolean ok = writer.persist(m);
            if (!ok) {
                log.warn("Redis 与 DB 库存不一致，少卖一单 orderNo={}", m.orderNo());
            }
            ack.acknowledge();
            log.debug("落库完成 orderNo={} partition={} offset={}",
                    m.orderNo(), record.partition(), record.offset());
        } catch (DuplicateKeyException e) {
            log.info("订单已存在，幂等跳过 orderNo={}", m.orderNo());
            ack.acknowledge();
        } catch (Exception e) {
            log.error("落库失败，将重投 orderNo={}", m.orderNo(), e);
            throw e;   // 不 ack → Kafka 重投
        }
    }
}
