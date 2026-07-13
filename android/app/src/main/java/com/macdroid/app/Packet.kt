package com.macdroid.app

import org.json.JSONObject

data class Packet(val type: String, val body: JSONObject = JSONObject()) {

    fun encode(): String = JSONObject().apply {
        put("id", System.currentTimeMillis())
        put("type", type)
        put("body", body)
    }.toString()

    companion object {
        fun decode(line: String): Packet? = try {
            val obj = JSONObject(line)
            Packet(obj.getString("type"), obj.optJSONObject("body") ?: JSONObject())
        } catch (_: Exception) {
            null
        }
    }
}
