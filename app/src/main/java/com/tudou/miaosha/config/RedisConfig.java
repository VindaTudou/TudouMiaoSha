package com.tudou.miaosha.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.redis.core.script.DefaultRedisScript;

/**
 * Spring Boot 已经自动配好了 StringRedisTemplate（key/value 都用 String 序列化），
 * 不需要自己再定义 RedisTemplate —— 定义了会出现两个同类型 bean，
 * 注入时报 "expected single matching bean but found 2"。
 */
@Configuration
public class RedisConfig {

    /**
     * Lua 脚本只加载一次，之后靠 SHA1 复用（EVALSHA），不用每次传脚本体。
     */
    @Bean
    public DefaultRedisScript<Long> stockDeductScript() {
        DefaultRedisScript<Long> script = new DefaultRedisScript<>();
        script.setLocation(new ClassPathResource("lua/stock_deduct.lua"));
        script.setResultType(Long.class);
        return script;
    }
}
