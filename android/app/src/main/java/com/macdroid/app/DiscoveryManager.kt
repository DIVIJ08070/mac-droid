package com.macdroid.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class DiscoveredMac(val name: String, val host: String, val port: Int)

/** Browses the local network for Macs advertising _macdroid._tcp via mDNS. */
class DiscoveryManager(context: Context) {

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _macs = MutableStateFlow<List<DiscoveredMac>>(emptyList())
    val macs: StateFlow<List<DiscoveredMac>> = _macs

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (discoveryListener != null) return
        _macs.value = emptyList()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!serviceInfo.serviceType.contains(SERVICE_TYPE_BASE)) return
                @Suppress("DEPRECATION")
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        Log.w(TAG, "Resolve failed for ${info.serviceName}: $errorCode")
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        val host = info.host?.hostAddress ?: return
                        val mac = DiscoveredMac(info.serviceName, host, info.port)
                        _macs.value = _macs.value.filter { it.name != mac.name } + mac
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                _macs.value = _macs.value.filter { it.name != serviceInfo.serviceName }
            }

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Discovery start failed: $errorCode")
                discoveryListener = null
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        discoveryListener = listener
        nsdManager.discoverServices("$SERVICE_TYPE_BASE.", NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stop() {
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        discoveryListener = null
    }

    companion object {
        private const val TAG = "MacDroidDiscovery"
        private const val SERVICE_TYPE_BASE = "_macdroid._tcp"
    }
}
