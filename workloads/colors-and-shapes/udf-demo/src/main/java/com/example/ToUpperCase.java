package com.example;

import org.apache.flink.table.functions.ScalarFunction;

public class ToUpperCase extends ScalarFunction {
    public String eval(String input) {
        return input == null ? null : input.toUpperCase();
    }
}
