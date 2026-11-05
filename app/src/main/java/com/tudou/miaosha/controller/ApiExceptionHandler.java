package com.tudou.miaosha.controller;

import com.tudou.miaosha.exception.DuplicateOrderException;
import com.tudou.miaosha.exception.NotFoundException;
import com.tudou.miaosha.exception.ServiceBusyException;
import com.tudou.miaosha.exception.SoldOutException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

/**
 * 错误码约定（压测脚本依赖这个约定做分类统计）：
 *   200 成功
 *   409 售罄      —— 业务结果，不算故障
 *   404 商品不存在
 *   5xx 系统错误  —— 这才是故障
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(SoldOutException.class)
    public ResponseEntity<Map<String, Object>> soldOut(SoldOutException e) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(Map.of("code", "SOLD_OUT", "message", e.getMessage()));
    }

    @ExceptionHandler(DuplicateOrderException.class)
    public ResponseEntity<Map<String, Object>> duplicate(DuplicateOrderException e) {
        return ResponseEntity.status(HttpStatus.CONFLICT)
                .body(Map.of("code", "DUPLICATE", "message", e.getMessage()));
    }

    @ExceptionHandler(ServiceBusyException.class)
    public ResponseEntity<Map<String, Object>> busy(ServiceBusyException e) {
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("code", "BUSY", "message", e.getMessage()));
    }

    @ExceptionHandler(NotFoundException.class)
    public ResponseEntity<Map<String, Object>> notFound(NotFoundException e) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(Map.of("code", "NOT_FOUND", "message", e.getMessage()));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, Object>> badRequest(IllegalArgumentException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("code", "BAD_REQUEST", "message", e.getMessage()));
    }
}
