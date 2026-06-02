package com.reactnativecommunity.webview.events

import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.events.Event
import com.facebook.react.uimanager.events.RCTEventEmitter

/**
 * Event emitted from the WebView's own MotionEvent stream when a gesture ends
 * (ACTION_UP / ACTION_POINTER_UP / ACTION_CANCEL). Unlike the RN touch responder,
 * this observes the WebView's native touch stream directly.
 */
class TopNativeTouchEndEvent(viewId: Int, private val mEventData: WritableMap) :
  Event<TopNativeTouchEndEvent>(viewId) {
  companion object {
    const val EVENT_NAME = "topNativeTouchEnd"
  }

  override fun getEventName(): String = EVENT_NAME

  override fun canCoalesce(): Boolean = false

  override fun getCoalescingKey(): Short = 0

  override fun dispatch(rctEventEmitter: RCTEventEmitter) =
    rctEventEmitter.receiveEvent(viewTag, eventName, mEventData)
}
