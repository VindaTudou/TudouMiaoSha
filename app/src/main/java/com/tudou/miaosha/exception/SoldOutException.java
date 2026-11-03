package com.tudou.miaosha.exception;

/**
 * 售罄。注意：这是【业务正常结果】，返回 409，不计入错误率。
 * 压测时如果把 409 算成失败，错误率会虚高到几十个百分点，结论全错。
 */
public class SoldOutException extends RuntimeException {
    public SoldOutException() {
        super("已售罄");
    }
}
