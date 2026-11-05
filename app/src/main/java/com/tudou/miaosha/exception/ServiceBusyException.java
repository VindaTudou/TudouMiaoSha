package com.tudou.miaosha.exception;

/** 发送 MQ 失败、已回滚库存，让用户重试。返回 503。 */
public class ServiceBusyException extends RuntimeException {
    public ServiceBusyException(String msg) {
        super(msg);
    }
}
