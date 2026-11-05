package com.tudou.miaosha.config;

import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.ConsumerFactory;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.core.MicrometerConsumerListener;

/**
 * 把 Kafka 客户端内部的指标绑定到 Micrometer。
 *
 * 最要紧的是这一个：kafka.consumer.fetch.manager.records.lag
 *   = 每个分区上「最新位点 − 已提交位点」
 *   = 还有多少单没落库
 *
 * V2 里 lag 是压测脚本临时起循环采的（for i in 1..300; lag; sleep 1），
 * 压测一停就什么都没有。线上出问题也看不到。
 *
 * 注意：lag 只对【真正被分配了分区】的消费者才有意义。
 * 所以这里不能自己 new 一个探针消费者绑指标——它没订阅主题，永远没有 lag。
 * 必须绑到 KafkaListener 容器实际使用的那个消费者上，
 * MicrometerConsumerListener 就是干这个的：工厂每造一个消费者，就绑一次。
 */
@Configuration
public class KafkaMetricsConfig {

    public KafkaMetricsConfig(ConsumerFactory<String, String> consumerFactory, MeterRegistry registry) {
        if (consumerFactory instanceof DefaultKafkaConsumerFactory<String, String> factory) {
            factory.addListener(new MicrometerConsumerListener<>(registry));
        }
    }
}
