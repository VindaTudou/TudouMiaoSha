package com.tudou.miaosha.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.tudou.miaosha.model.OrderMessage;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;

import java.util.concurrent.TimeUnit;

@Service
public class OrderProducer {

    private final KafkaTemplate<String, String> kafka;
    private final ObjectMapper om;
    private final String topic;

    public OrderProducer(KafkaTemplate<String, String> kafka,
                         ObjectMapper om,
                         @Value("${miaosha.order-topic}") String topic) {
        this.kafka = kafka;
        this.om = om;
        this.topic = topic;
    }

    /**
     * 同步等 Kafka 确认（最多 3 秒）。
     *
     * 为什么不等异步回调：因为要能在失败时立刻回滚 Redis 库存。
     * 异步回调也能做，但请求线程已经返回了，回滚语义会变复杂。
     *
     * 代价：每次下单多一次网络往返（约 1-5ms，linger.ms=5 会再攒一下）。
     * 这是「可靠性 vs 延迟」的取舍，V2 先选可靠性。
     */
    public void send(OrderMessage msg) throws Exception {
        kafka.send(topic, String.valueOf(msg.productId()), om.writeValueAsString(msg))
                .get(3, TimeUnit.SECONDS);
    }
}
