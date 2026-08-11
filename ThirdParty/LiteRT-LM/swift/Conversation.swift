// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import OSLog
import CLiteRTLM

typealias CConversationHandle = OpaquePointer

private let streamLogger = Logger(
  subsystem: "com.google.ai.edge.litertlm.swift",
  category: "Conversation"
)

private let recurringToolCallLimit = 25

private struct StreamCallbackEvent: Sendable {
  let responseString: String?
  let isFinal: Bool
  let errorMessage: String?
  let userDataAddress: UInt
}

/// Represents a conversation with the LiteRT-LM model.
///
/// Example usage:
/// ```swift
/// // Assuming 'engine' is an instance of Engine
/// let conversation = try await engine.createConversation()
///
/// // Send a message and get the response.
/// let response = try await conversation.sendMessage(Message("Hello world"))
///
/// // Send a message async with response chunks as AsyncThrowingStream.
/// for try await chunk in await conversation.sendMessageStream(Message("Hello world")) {
///   print(chunk.text)
/// }
/// ```
///
/// This actor facilitates interaction with the LiteRT-LM model by handling message sending
/// and response reception.
/// Owns a single native conversation handle and serializes every operation on
/// that handle.  The C API is stateful (send, stream and cancel all mutate the
/// same session), so exposing it as an ordinary class allowed callers from
/// different tasks to race.  Making the owner an actor gives Swift 6 a real
/// isolation boundary instead of relying on an `@unchecked Sendable` wrapper
/// in each application.
public actor Conversation {
  private let logger = Logger(
    subsystem: "com.google.ai.edge.litertlm.swift",
    category: "Conversation"
  )

  private var handle: CConversationHandle?
  private let toolManager: ToolManager

  /// Whether the conversation is alive and ready to be used.
  public var isAlive: Bool {
    return handle != nil
  }

  init(handle: CConversationHandle, toolManager: ToolManager) {
    self.handle = handle
    self.toolManager = toolManager
  }

  deinit {
    if let handle = handle {
      litert_lm_conversation_delete(handle)
    }
  }

  /// Sends a message to the model and returns the response. This is a synchronous call.
  ///
  /// - Parameter message: The message to send to the model.
  /// - Parameter extraContext: The extra context to send to the model.
  /// - Returns: The model's response message.
  /// - Throws: A `LiteRTLMError` if sending the message fails or the model
  ///   returns an invalid response.
  public nonisolated func sendMessage(
    _ message: Message, extraContext: [String: Any]? = nil
  ) async throws -> Message {
    // `[String: Any]` is intentionally kept in the source-compatible public
    // API, but it must not cross an actor boundary. Serialize it before
    // entering the owner actor so the native handle only receives Sendable
    // values.
    let extraContextJSON = try Self.serializeExtraContext(extraContext)
    return try await sendMessageOnActor(message, extraContextJSON: extraContextJSON)
  }

  private func sendMessageOnActor(
    _ message: Message, extraContextJSON: String?
  ) async throws -> Message {
    let handle = try checkIsAlive()

    var currentMessageJson: [String: Any] = message.toJson

    for _ in 0..<recurringToolCallLimit {
      let (responseJson, responseString) = try attemptSendMessage(
        handle: handle, messageJson: currentMessageJson, extraContextJSON: extraContextJSON)

      guard let toolCalls = responseJson["tool_calls"] as? [[String: Any]] else {
        if responseJson["content"] != nil || responseJson["channels"] != nil {
          return try Conversation.jsonToMessage(responseString)
        } else {
          throw LiteRTLMError.conversation(.invalidResponse(responseString))
        }
      }
      currentMessageJson = try await handleToolCalls(toolCalls)
    }
    throw LiteRTLMError.conversation(.recurringToolCallLimitExceeded(limit: recurringToolCallLimit))
  }

  private func attemptSendMessage(
    handle: CConversationHandle, messageJson: [String: Any], extraContextJSON: String?
  ) throws
    -> (responseJson: [String: Any], responseString: String)
  {
    let messageData = try JSONSerialization.data(withJSONObject: messageJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    let optionalArgs = litert_lm_conversation_optional_args_create()
    if let visualTokenBudget = ExperimentalFlags.visualTokenBudget {
      litert_lm_conversation_optional_args_set_visual_token_budget(
        optionalArgs, Int32(visualTokenBudget))
    }
    defer { litert_lm_conversation_optional_args_delete(optionalArgs) }

    guard
      let responsePtr = litert_lm_conversation_send_message(
        handle, messageString, extraContextJSON, optionalArgs)
    else {
      throw LiteRTLMError.conversation(.invalidResponse("Native sendMessage returned null."))

    }
    // Delete the response pointer at the end of each iteration. Handled by defer block.
    let responsePtrRef = responsePtr
    defer { litert_lm_json_response_delete(responsePtrRef) }

    guard let responseChars = litert_lm_json_response_get_string(responsePtr) else {
      throw LiteRTLMError.conversation(
        .invalidResponse("Native get string for response returned null."))
    }
    let responseString = String(cString: responseChars)

    guard let responseData = responseString.data(using: .utf8),
      let responseJson = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw LiteRTLMError.conversation(.invalidJson("Failed to parse native response JSON."))
    }
    return (responseJson, responseString)
  }

  fileprivate func handleToolCalls(_ toolCalls: [[String: Any]]) async throws -> [String: Any] {
    var toolResponses: [[String: Any]] = []

    for toolCall in toolCalls {
      guard let function = toolCall["function"] as? [String: Any],
        let name = function["name"] as? String,
        let argsObject = function["arguments"] as? [String: Any]
      else {
        continue
      }
      do {
        let result = try await toolManager.execute(name: name, arguments: argsObject)

        toolResponses.append([
          "type": "tool_response",
          "name": name,
          "response": result,
        ])
      } catch {
        throw LiteRTLMError.conversation(.toolExecutionError(name: name, error: "\(error)"))
      }
    }

    return ["role": "tool", "content": toolResponses]
  }

  /// Throws an error if the conversation is not alive.
  ///
  /// - Returns: The `OpaquePointer` handle if the conversation is alive.
  /// - Throws: A `LiteRTLMError` if `handle` is nil, indicating the conversation is not alive.
  fileprivate func checkIsAlive() throws -> OpaquePointer {
    guard let handle else {
      throw LiteRTLMError.conversation(.notAlive)
    }
    return handle
  }

  /// Sends a message to the model and returns an async stream of response chunks.
  ///
  /// - Parameter message: The message to send.
  /// - Parameter extraContext: The extra context to send to the model.
  /// - Returns: An async throwing stream of `Message` chunks.
  /// Starts a stream while the actor is holding the conversation boundary.
  /// Installing the native callback before returning prevents a caller's
  /// immediate `cancel()` from racing ahead of stream setup.
  public func sendMessageStream(
    _ message: Message, extraContext: [String: Any]? = nil
  ) -> AsyncThrowingStream<Message, Error> {
    let extraContextJSON: String?
    do {
      // Do not turn a malformed context into an apparently valid request.
      // The stream must surface serialization failures to its consumer.
      extraContextJSON = try Self.serializeExtraContext(extraContext)
    } catch let error as LiteRTLMError {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
      }
    } catch {
      let streamError = LiteRTLMError.conversation(
        .invalidResponse("Failed to serialize extra context: \(error.localizedDescription)"))
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: streamError)
      }
    }

    return AsyncThrowingStream { continuation in
      do {
        let handle = try self.checkIsAlive()
        let messageJson: [String: Any] = message.toJson
        let context = StreamContext(
          continuation: continuation, conversation: self)

        // Consumer cancellation must reach the native conversation.  The
        // callback context is actor-owned, so the termination hook is safe to
        // install before the first native callback can arrive.
        continuation.onTermination = { @Sendable [weak context] _ in
          Task { await context?.cancelIfActive() }
        }

        do {
          try self.sendToStream(
            handle: handle, messageJson: messageJson, extraContextJSON: extraContextJSON,
            context: context)
        } catch let error as LiteRTLMError {
          continuation.finish(throwing: error)
          Task { await context.finishWithoutNativeRetain(throwing: error) }
        } catch {
          let streamError = LiteRTLMError.conversation(
            .invalidResponse("Failed to start stream: \(error.localizedDescription)"))
          continuation.finish(throwing: streamError)
          Task { await context.finishWithoutNativeRetain(throwing: streamError) }
        }
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  /// Sends a message to the model and handles the response via a streaming callback.
  ///
  /// This function is used internally by `sendMessageStream` and for handling
  /// subsequent tool call responses within the stream.
  ///
  /// - Parameters:
  ///   - handle: The `CConversationHandle` for the current conversation.
  ///   - messageJson: The message to send, represented as a JSON dictionary.
  ///   - extraContext: The extra context to send to the model.
  ///   - context: The `StreamContext` containing the `AsyncThrowingStream.Continuation`
  ///     and other state for the streaming process.
  /// - Throws: A `LiteRTLMError` if the message fails to send or the response is invalid.
  ///   native `send_message_stream` call fails.
  func sendToStream(
    handle: CConversationHandle,
    messageJson: [String: Any],
    extraContextJSON: String? = nil,
    context: StreamContext
  ) throws {
    let messageData = try JSONSerialization.data(withJSONObject: messageJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    let optionalArgs = litert_lm_conversation_optional_args_create()
    if let visualTokenBudget = ExperimentalFlags.visualTokenBudget {
      litert_lm_conversation_optional_args_set_visual_token_budget(
        optionalArgs, Int32(visualTokenBudget))
    }
    defer { litert_lm_conversation_optional_args_delete(optionalArgs) }

    let contextPtr = Unmanaged.passRetained(context).toOpaque()

    let status = litert_lm_conversation_send_message_stream(
      handle,
      messageString,
      extraContextJSON,
      optionalArgs,
      streamCallback,
      contextPtr
    )

    guard status == 0 else {
      Unmanaged<StreamContext>.fromOpaque(contextPtr).release()
      throw LiteRTLMError.conversation(.failedToStartStream(status: Int(status)))
    }
  }

  /// Handles a completed stream turn that contains tool calls.  The callback
  /// actor passes only JSON strings across this boundary; decoding and tool
  /// execution stay inside the Conversation actor where the native handle and
  /// the ToolManager are isolated.
  fileprivate func continueStreamAfterToolCallResponses(
    _ responseStrings: [String],
    context: StreamContext
  ) async throws {
    var toolCalls: [[String: Any]] = []
    for responseString in responseStrings {
      guard let data = responseString.data(using: .utf8),
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let responseToolCalls = jsonObject["tool_calls"] as? [[String: Any]
        ]
      else {
        throw LiteRTLMError.conversation(.invalidJson("Invalid tool call response JSON"))
      }
      toolCalls.append(contentsOf: responseToolCalls)
    }

    let toolResponseJson = try await handleToolCalls(toolCalls)
    let handle = try checkIsAlive()
    try sendToStream(handle: handle, messageJson: toolResponseJson, context: context)
  }

  private nonisolated static func serializeExtraContext(
    _ extraContext: [String: Any]?
  ) throws -> String? {
    guard let extraContext, !extraContext.isEmpty else { return nil }
    let data = try JSONSerialization.data(withJSONObject: extraContext)
    guard let string = String(data: data, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }
    return string
  }

  /// Cancels the ongoing asynchronous inference process.
  public func cancel() throws {
    let handle = try checkIsAlive()
    litert_lm_conversation_cancel_process(handle)
  }

  /// Renders the message into a string for testing and logging.
  ///
  /// This function does not need to be called for actual message sending, as the `sendMessage` and
  /// `sendMessageStream` functions will handle rendering internally.
  ///
  /// - Parameter message: The message to render.
  /// - Returns: The rendered message string.
  /// - Throws: A `LiteRTLMError` if the conversation is not alive, serializing fails, or rendering fails.
  public func renderMessageIntoString(_ message: Message) throws -> String {
    let handle = try checkIsAlive()
    let messageData = try JSONSerialization.data(withJSONObject: message.toJson)
    guard let messageString = String(data: messageData, encoding: .utf8) else {
      throw LiteRTLMError.conversation(.failedToSerializeMessage)
    }

    guard let cString = litert_lm_conversation_render_message_to_string(handle, messageString)
    else {
      throw LiteRTLMError.conversation(.invalidResponse("Failed to render message into string."))
    }
    return String(cString: cString)
  }

  /// Renders the preface into a string for testing and logging.
  ///
  /// - Returns: The rendered preface string.
  /// - Throws: A `LiteRTLMError` if the conversation is not alive, or rendering fails.
  public func renderPrefaceIntoString() throws -> String {
    let handle = try checkIsAlive()
    guard let cString = litert_lm_conversation_render_preface_to_string(handle) else {
      throw LiteRTLMError.conversation(.invalidResponse("Failed to render preface into string."))
    }
    return String(cString: cString)
  }

  /// Gets the number of tokens in the conversation KV Cache (prefill + decode).
  ///
  /// - Throws: A `LiteRTLMError` if the conversation is not alive.
  public func getTokenCount() throws -> Int {
    let handle = try checkIsAlive()
    return Int(litert_lm_conversation_get_token_count(handle))
  }

  /// Retrieves the benchmark information from the conversation.
  ///
  /// - Returns: The benchmark information
  /// - Throws: A `LiteRTLMError` if the benchmark flag is not enabled or info is unavailable.
  public func getBenchmarkInfo() throws -> BenchmarkInfo {
    let handle = try checkIsAlive()

    if !ExperimentalFlags.enableBenchmark {
      throw LiteRTLMError.conversation(.benchmarkNotEnabled)
    }

    guard let benchmarkInfoPtr = litert_lm_conversation_get_benchmark_info(handle) else {
      throw LiteRTLMError.conversation(.benchmarkInfoUnavailable)
    }
    defer { litert_lm_benchmark_info_delete(benchmarkInfoPtr) }

    let numPrefillTurns = litert_lm_benchmark_info_get_num_prefill_turns(benchmarkInfoPtr)
    let numDecodeTurns = litert_lm_benchmark_info_get_num_decode_turns(benchmarkInfoPtr)

    let initTimeInSecond = litert_lm_benchmark_info_get_total_init_time_in_second(benchmarkInfoPtr)
    let timeToFirstTokenInSecond = litert_lm_benchmark_info_get_time_to_first_token(
      benchmarkInfoPtr)

    let lastPrefillTokenCount: Int =
      numPrefillTurns > 0
      ? Int(
        litert_lm_benchmark_info_get_prefill_token_count_at(
          benchmarkInfoPtr, numPrefillTurns - 1)) : 0
    let lastPrefillTokensPerSec: Double =
      numPrefillTurns > 0
      ? litert_lm_benchmark_info_get_prefill_tokens_per_sec_at(
        benchmarkInfoPtr, numPrefillTurns - 1) : 0.0

    let lastDecodeTokenCount: Int =
      numDecodeTurns > 0
      ? Int(
        litert_lm_benchmark_info_get_decode_token_count_at(
          benchmarkInfoPtr, numDecodeTurns - 1)) : 0
    let lastDecodeTokensPerSec: Double =
      numDecodeTurns > 0
      ? litert_lm_benchmark_info_get_decode_tokens_per_sec_at(
        benchmarkInfoPtr, numDecodeTurns - 1) : 0.0

    return BenchmarkInfo(
      initTimeInSecond: initTimeInSecond,
      timeToFirstTokenInSecond: timeToFirstTokenInSecond,
      lastPrefillTokenCount: lastPrefillTokenCount,
      lastDecodeTokenCount: lastDecodeTokenCount,
      lastPrefillTokensPerSecond: lastPrefillTokensPerSec,
      lastDecodeTokensPerSecond: lastDecodeTokensPerSec
    )
  }

  /// Internal Helper Function to convert a JSON string to a `Message`.
  ///
  /// - Parameter jsonString: The JSON string to convert.
  /// - Returns: The `Message` representation of the JSON string.
  /// - Throws: `LiteRTLMError` if the JSON string is invalid.
  public static func jsonToMessage(_ jsonString: String) throws -> Message {
    guard let data = jsonString.data(using: .utf8),
      let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw LiteRTLMError.message(.failedToConvertToJson)
    }

    var contents: [Content] = []
    if let contentArray = jsonObject["content"] as? [[String: Any]] {
      for item in contentArray {
        if let type = item["type"] as? String, type == "text", let text = item["text"] as? String {
          contents.append(.text(text))
        }
      }
    }

    var channels: [String: String] = [:]
    if let channelsDict = jsonObject["channels"] as? [String: Any] {
      for (key, value) in channelsDict {
        if let strValue = value as? String {
          channels[key] = strValue
        }
      }
    }

    if contents.isEmpty && channels.isEmpty {
      throw LiteRTLMError.message(.invalidContent)
    }

    return Message(contents: contents, channels: channels)
  }

  /// Context object to bridge the C callback to the Swift AsyncThrowingStream.
  /// Serializes callback delivery and owns the continuation for one native
  /// stream.  Native callbacks may arrive on arbitrary threads; routing each
  /// event through this actor prevents concurrent mutation of pending tool
  /// calls and guarantees that the retained context is released exactly once.
  actor StreamContext {
    let continuation: AsyncThrowingStream<Message, Error>.Continuation
    let conversation: Conversation
    private let callbackContinuation: AsyncStream<StreamCallbackEvent>.Continuation
    private var callbackConsumer: Task<Void, Never>?
    private var isFinished = false
    var toolCallCount: Int = 0
    // Keep callback payloads as JSON strings while they are in this actor.
    // `[String: Any]` is not Sendable and must be decoded only after control
    // returns to the owning Conversation actor.
    var pendingToolCallResponses: [String] = []

    init(
      continuation: AsyncThrowingStream<Message, Error>.Continuation,
      conversation: Conversation
    ) {
      let callbackStream = AsyncStream<StreamCallbackEvent>.makeStream()
      self.continuation = continuation
      self.conversation = conversation
      self.callbackContinuation = callbackStream.continuation
      self.callbackConsumer = nil
      self.callbackConsumer = Task { [weak self] in
        for await event in callbackStream.stream {
          await self?.receive(
            responseString: event.responseString,
            isFinal: event.isFinal,
            errorMessage: event.errorMessage,
            userDataAddress: event.userDataAddress
          )
        }
      }
    }

    /// Called directly from the C callback. AsyncStream's continuation is
    /// thread-safe and keeps callback order; a single consumer task then
    /// invokes `receive` on this actor.
    nonisolated func enqueue(
      responseString: String?,
      isFinal: Bool,
      errorMessage: String?,
      userDataAddress: UInt
    ) {
      callbackContinuation.yield(
        StreamCallbackEvent(
          responseString: responseString,
          isFinal: isFinal,
          errorMessage: errorMessage,
          userDataAddress: userDataAddress
        )
      )
    }

    private func receive(
      responseString: String?,
      isFinal: Bool,
      errorMessage: String?,
      userDataAddress: UInt
    ) async {
      guard !isFinished else { return }

      if let errorMessage {
        let error = LiteRTLMError.conversation(.invalidResponse(errorMessage))
        finish(throwing: error, userDataAddress: userDataAddress)
        return
      }

      if let responseString {
        do {
          guard let responseData = responseString.data(using: .utf8),
            let jsonObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
          else {
            throw LiteRTLMError.conversation(.invalidJson("Invalid JSON chunk"))
          }

          if jsonObject["tool_calls"] is [[String: Any]] {
            pendingToolCallResponses.append(responseString)
          }

          if jsonObject["content"] != nil || jsonObject["channels"] != nil {
            let message = try Conversation.jsonToMessage(responseString)
            continuation.yield(message)
          }
        } catch {
          streamLogger.error("Failed to parse response JSON: \(error.localizedDescription)")
          let streamError = (error as? LiteRTLMError)
            ?? LiteRTLMError.conversation(.invalidResponse(error.localizedDescription))
          finish(throwing: streamError, userDataAddress: userDataAddress)
          return
        }
      }

      guard isFinal else { return }

      if !pendingToolCallResponses.isEmpty {
        if toolCallCount >= recurringToolCallLimit {
          finish(
            throwing: LiteRTLMError.conversation(
              .recurringToolCallLimitExceeded(limit: recurringToolCallLimit)),
            userDataAddress: userDataAddress
          )
          return
        }

        toolCallCount += 1
        let toolCallResponses = pendingToolCallResponses
        pendingToolCallResponses = []

        do {
          try await conversation.continueStreamAfterToolCallResponses(
            toolCallResponses,
            context: self
          )
        } catch {
          let streamError = (error as? LiteRTLMError)
            ?? LiteRTLMError.conversation(.invalidResponse(error.localizedDescription))
          finish(throwing: streamError, userDataAddress: userDataAddress)
          return
        }
        // The next native call retains the context again. Release the retain
        // belonging to the callback that just finished.
        release(userDataAddress)
      } else {
        finish(userDataAddress: userDataAddress)
      }
    }

    /// Finishes a stream whose native call failed before a callback retained
    /// the context. This path intentionally does not release userData.
    func finishWithoutNativeRetain(throwing error: LiteRTLMError) {
      guard !isFinished else { return }
      isFinished = true
      callbackContinuation.finish()
      callbackConsumer?.cancel()
      continuation.finish(throwing: error)
    }

    /// Cancels only an active native stream. Normal completion marks the
    /// context finished first, so onTermination cannot cancel a later reuse.
    func cancelIfActive() async {
      guard !isFinished else { return }
      try? await conversation.cancel()
    }

    private func finish(throwing error: LiteRTLMError? = nil, userDataAddress: UInt) {
      guard !isFinished else { return }
      isFinished = true
      callbackContinuation.finish()
      callbackConsumer?.cancel()
      if let error {
        continuation.finish(throwing: error)
      } else {
        continuation.finish()
      }
      release(userDataAddress)
    }

    private func release(_ userDataAddress: UInt) {
      guard let userData = UnsafeMutableRawPointer(bitPattern: userDataAddress) else { return }
      Unmanaged<StreamContext>.fromOpaque(userData).release()
    }
  }
}

/// A callback function to bridge the C callback to the Swift AsyncThrowingStream.
private func streamCallback(
  userData: UnsafeMutableRawPointer?,
  responseJson: UnsafePointer<CChar>?,
  isFinal: Bool,
  errorMessage: UnsafePointer<CChar>?
) {
  guard let userData = userData else { return }

  let context = Unmanaged<Conversation.StreamContext>.fromOpaque(userData).takeUnretainedValue()
  let responseString = responseJson.map { String(cString: $0) }
  let errorString = errorMessage.map { String(cString: $0) }
  let userDataAddress = UInt(bitPattern: userData)

  // The native callback is not actor-isolated. Convert its C pointers to
  // owned Swift strings before enqueuing; StreamContext's single consumer
  // serializes delivery and releases the retained context after the event.
  context.enqueue(
    responseString: responseString,
    isFinal: isFinal,
    errorMessage: errorString,
    userDataAddress: userDataAddress
  )
}
