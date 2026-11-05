package com.tudou.miaosha.exception;

/** 同一个用户重复下单。Lua 里用 SET 去重，返回 409。 */
public class DuplicateOrderException extends RuntimeException {
    public DuplicateOrderException() {
        super("您已经下过单了");
    }
}
