package com.timbertrail.screentimeguardian

object GuardianRuntime {
    @Volatile var serviceStatus: String = "后台服务未启动"
    @Volatile var p2pTransport: P2PTransport? = null
}
