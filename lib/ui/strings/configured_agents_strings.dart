// Copyright 2024 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// Customizable text for the configured-agents UI.
///
/// Override any field to localize or rebrand. Defaults are US English. Mirrors
/// the customization approach of `LlmChatViewStrings`.
@immutable
class ConfiguredAgentsStrings {
  /// Default instance with all default values.
  static const ConfiguredAgentsStrings defaults = ConfiguredAgentsStrings();

  /// Creates a [ConfiguredAgentsStrings].
  const ConfiguredAgentsStrings({
    this.sourcesTab = 'Sources',
    this.modelsTab = 'Models',
    this.agentsTab = 'Agents',
    this.addSource = 'Add source',
    this.addModel = 'Add model',
    this.addAgent = 'Add agent',
    this.editSource = 'Edit source',
    this.editModel = 'Edit model',
    this.editAgent = 'Edit agent',
    this.providerLabel = 'Provider',
    this.displayNameLabel = 'Display name',
    this.endpointLabel = 'Endpoint (optional)',
    this.apiKeyLabel = 'API key',
    this.apiKeyStoredHint = 'A key is stored. Leave blank to keep it.',
    this.sourceLabel = 'Source',
    this.modelIdLabel = 'Model id',
    this.modelDisplayNameLabel = 'Display name (optional)',
    this.nameLabel = 'Name',
    this.descriptionLabel = 'Description (optional)',
    this.instructionsLabel = 'Instructions',
    this.modelLabel = 'Model',
    this.temperatureLabel = 'Temperature (optional)',
    this.maxOutputTokensLabel = 'Max output tokens (optional)',
    this.agentToolsLabel = 'Tools',
    this.agentContextLabel = 'Context',
    this.fileMemoryAccessLabel = 'File memory',
    this.fileAccessLabel = 'File access',
    this.fileWriteToolsLabel = 'File write tools',
    this.fileToolApprovalLabel = 'File tool approvals',
    this.fileToolApprovalAlwaysAsk = 'Always ask',
    this.fileToolApprovalAutoReadOnly = 'Auto-approve read-only',
    this.fileToolApprovalAutoAll = 'Auto-approve all',
    this.webSearchAccessLabel = 'Web search',
    this.todoListAccessLabel = 'Todo list',
    this.agentModeAccessLabel = 'Agent mode',
    this.skillsAccessLabel = 'Skills',
    this.temporalAccessLabel = 'Time',
    this.connectivityAccessLabel = 'Connectivity',
    this.appInfoAccessLabel = 'App info',
    this.deviceInfoAccessLabel = 'Device info',
    this.locationAccessLabel = 'Location',
    this.networkInfoAccessLabel = 'Network info',
    this.wakeLockAccessLabel = 'Wake lock',
    this.openAiCompatibleProvider = 'OpenAI-compatible',
    this.anthropicProvider = 'Anthropic',
    this.googleProvider = 'Google (Gemini)',
    this.save = 'Save',
    this.cancel = 'Cancel',
    this.delete = 'Delete',
    this.edit = 'Edit',
    this.copy = 'Copy',
    this.confirmDeleteTitle = 'Confirm delete',
    this.confirmDeleteMessage = 'Are you sure you want to delete this item?',
    this.cascadeDelete = 'Delete anyway',
    this.requiredField = 'Required',
    this.invalidNumber = 'Enter a valid number',
    this.invalidEndpoint = 'Enter a valid URL',
    this.noSources = 'No sources yet. Add one to get started.',
    this.noModels = 'No models yet. Add a source, then a model.',
    this.noAgents = 'No agents yet. Add a model, then an agent.',
    this.selectModelFirst = 'Add a model before creating an agent.',
    this.delegationLabel = 'Delegates',
    this.delegationGuidanceLabel = 'Delegation guidance (optional)',
    this.delegationGuidanceHint = 'When should this agent be used?',
  });

  /// Label for the sources tab.
  final String sourcesTab;

  /// Label for the models tab.
  final String modelsTab;

  /// Label for the agents tab.
  final String agentsTab;

  /// Action label to add a source.
  final String addSource;

  /// Action label to add a model.
  final String addModel;

  /// Action label to add an agent.
  final String addAgent;

  /// Title for the source editor when editing.
  final String editSource;

  /// Title for the model editor when editing.
  final String editModel;

  /// Title for the agent editor when editing.
  final String editAgent;

  /// Field label for a source's provider type.
  final String providerLabel;

  /// Field label for a source's display name.
  final String displayNameLabel;

  /// Field label for a source's optional endpoint.
  final String endpointLabel;

  /// Field label for a source's API key.
  final String apiKeyLabel;

  /// Hint shown when a key is already stored.
  final String apiKeyStoredHint;

  /// Field label for a model's owning source.
  final String sourceLabel;

  /// Field label for a model's provider model id.
  final String modelIdLabel;

  /// Field label for a model's optional display name.
  final String modelDisplayNameLabel;

  /// Field label for an agent's name.
  final String nameLabel;

  /// Field label for an agent's optional description.
  final String descriptionLabel;

  /// Field label for an agent's instructions.
  final String instructionsLabel;

  /// Field label for an agent's model.
  final String modelLabel;

  /// Field label for an agent's optional temperature.
  final String temperatureLabel;

  /// Field label for an agent's optional max output tokens.
  final String maxOutputTokensLabel;

  /// Section label for agent tool access.
  final String agentToolsLabel;

  /// Section label for agent context access.
  final String agentContextLabel;

  /// Label for file-memory access.
  final String fileMemoryAccessLabel;

  /// Label for file-access context.
  final String fileAccessLabel;

  /// Label for the file write tools toggle.
  final String fileWriteToolsLabel;

  /// Label for the file tool approval mode picker.
  final String fileToolApprovalLabel;

  /// Approval mode label: prompt for every file tool call.
  final String fileToolApprovalAlwaysAsk;

  /// Approval mode label: auto-approve read-only file tools.
  final String fileToolApprovalAutoReadOnly;

  /// Approval mode label: auto-approve all file tools.
  final String fileToolApprovalAutoAll;

  /// Label for hosted web-search tool access.
  final String webSearchAccessLabel;

  /// Label for todo-list context access.
  final String todoListAccessLabel;

  /// Label for agent-mode context access.
  final String agentModeAccessLabel;

  /// Label for skill context access.
  final String skillsAccessLabel;

  /// Label for temporal context/tool access.
  final String temporalAccessLabel;

  /// Label for connectivity context/tool access.
  final String connectivityAccessLabel;

  /// Label for app-info tool access.
  final String appInfoAccessLabel;

  /// Label for device-info context/tool access.
  final String deviceInfoAccessLabel;

  /// Label for location context/tool access.
  final String locationAccessLabel;

  /// Label for detailed network context/tool access.
  final String networkInfoAccessLabel;

  /// Label for wake-lock tool access.
  final String wakeLockAccessLabel;

  /// Display label for the OpenAI-compatible provider.
  final String openAiCompatibleProvider;

  /// Display label for the Anthropic provider.
  final String anthropicProvider;

  /// Display label for the Google (Gemini) provider.
  final String googleProvider;

  /// Label for the save action.
  final String save;

  /// Label for the cancel action.
  final String cancel;

  /// Label for the delete action.
  final String delete;

  /// Label for the edit action.
  final String edit;

  /// Label for the copy action.
  final String copy;

  /// Title for the delete confirmation dialog.
  final String confirmDeleteTitle;

  /// Body for the delete confirmation dialog.
  final String confirmDeleteMessage;

  /// Label for the cascade (force) delete action.
  final String cascadeDelete;

  /// Validation message for a missing required field.
  final String requiredField;

  /// Validation message for an invalid number.
  final String invalidNumber;

  /// Validation message for an invalid endpoint URL.
  final String invalidEndpoint;

  /// Empty-state message for the sources list.
  final String noSources;

  /// Empty-state message for the models list.
  final String noModels;

  /// Empty-state message for the agents list.
  final String noAgents;

  /// Message shown in the agent editor when no models exist yet.
  final String selectModelFirst;

  /// Section label for an agent's delegate agents.
  final String delegationLabel;

  /// Field label for a delegate's routing guidance.
  final String delegationGuidanceLabel;

  /// Hint for a delegate's routing guidance field.
  final String delegationGuidanceHint;

  /// Returns a copy with the given fields replaced.
  ConfiguredAgentsStrings copyWith({
    String? sourcesTab,
    String? modelsTab,
    String? agentsTab,
    String? addSource,
    String? addModel,
    String? addAgent,
    String? editSource,
    String? editModel,
    String? editAgent,
    String? providerLabel,
    String? displayNameLabel,
    String? endpointLabel,
    String? apiKeyLabel,
    String? apiKeyStoredHint,
    String? sourceLabel,
    String? modelIdLabel,
    String? modelDisplayNameLabel,
    String? nameLabel,
    String? descriptionLabel,
    String? instructionsLabel,
    String? modelLabel,
    String? temperatureLabel,
    String? maxOutputTokensLabel,
    String? agentToolsLabel,
    String? agentContextLabel,
    String? fileMemoryAccessLabel,
    String? fileAccessLabel,
    String? fileWriteToolsLabel,
    String? fileToolApprovalLabel,
    String? fileToolApprovalAlwaysAsk,
    String? fileToolApprovalAutoReadOnly,
    String? fileToolApprovalAutoAll,
    String? webSearchAccessLabel,
    String? todoListAccessLabel,
    String? agentModeAccessLabel,
    String? skillsAccessLabel,
    String? temporalAccessLabel,
    String? connectivityAccessLabel,
    String? appInfoAccessLabel,
    String? deviceInfoAccessLabel,
    String? locationAccessLabel,
    String? networkInfoAccessLabel,
    String? wakeLockAccessLabel,
    String? openAiCompatibleProvider,
    String? anthropicProvider,
    String? googleProvider,
    String? save,
    String? cancel,
    String? delete,
    String? edit,
    String? copy,
    String? confirmDeleteTitle,
    String? confirmDeleteMessage,
    String? cascadeDelete,
    String? requiredField,
    String? invalidNumber,
    String? invalidEndpoint,
    String? noSources,
    String? noModels,
    String? noAgents,
    String? selectModelFirst,
    String? delegationLabel,
    String? delegationGuidanceLabel,
    String? delegationGuidanceHint,
  }) => ConfiguredAgentsStrings(
    sourcesTab: sourcesTab ?? this.sourcesTab,
    modelsTab: modelsTab ?? this.modelsTab,
    agentsTab: agentsTab ?? this.agentsTab,
    addSource: addSource ?? this.addSource,
    addModel: addModel ?? this.addModel,
    addAgent: addAgent ?? this.addAgent,
    editSource: editSource ?? this.editSource,
    editModel: editModel ?? this.editModel,
    editAgent: editAgent ?? this.editAgent,
    providerLabel: providerLabel ?? this.providerLabel,
    displayNameLabel: displayNameLabel ?? this.displayNameLabel,
    endpointLabel: endpointLabel ?? this.endpointLabel,
    apiKeyLabel: apiKeyLabel ?? this.apiKeyLabel,
    apiKeyStoredHint: apiKeyStoredHint ?? this.apiKeyStoredHint,
    sourceLabel: sourceLabel ?? this.sourceLabel,
    modelIdLabel: modelIdLabel ?? this.modelIdLabel,
    modelDisplayNameLabel: modelDisplayNameLabel ?? this.modelDisplayNameLabel,
    nameLabel: nameLabel ?? this.nameLabel,
    descriptionLabel: descriptionLabel ?? this.descriptionLabel,
    instructionsLabel: instructionsLabel ?? this.instructionsLabel,
    modelLabel: modelLabel ?? this.modelLabel,
    temperatureLabel: temperatureLabel ?? this.temperatureLabel,
    maxOutputTokensLabel: maxOutputTokensLabel ?? this.maxOutputTokensLabel,
    agentToolsLabel: agentToolsLabel ?? this.agentToolsLabel,
    agentContextLabel: agentContextLabel ?? this.agentContextLabel,
    fileMemoryAccessLabel: fileMemoryAccessLabel ?? this.fileMemoryAccessLabel,
    fileAccessLabel: fileAccessLabel ?? this.fileAccessLabel,
    fileWriteToolsLabel: fileWriteToolsLabel ?? this.fileWriteToolsLabel,
    fileToolApprovalLabel: fileToolApprovalLabel ?? this.fileToolApprovalLabel,
    fileToolApprovalAlwaysAsk:
        fileToolApprovalAlwaysAsk ?? this.fileToolApprovalAlwaysAsk,
    fileToolApprovalAutoReadOnly:
        fileToolApprovalAutoReadOnly ?? this.fileToolApprovalAutoReadOnly,
    fileToolApprovalAutoAll:
        fileToolApprovalAutoAll ?? this.fileToolApprovalAutoAll,
    webSearchAccessLabel: webSearchAccessLabel ?? this.webSearchAccessLabel,
    todoListAccessLabel: todoListAccessLabel ?? this.todoListAccessLabel,
    agentModeAccessLabel: agentModeAccessLabel ?? this.agentModeAccessLabel,
    skillsAccessLabel: skillsAccessLabel ?? this.skillsAccessLabel,
    temporalAccessLabel: temporalAccessLabel ?? this.temporalAccessLabel,
    connectivityAccessLabel:
        connectivityAccessLabel ?? this.connectivityAccessLabel,
    appInfoAccessLabel: appInfoAccessLabel ?? this.appInfoAccessLabel,
    deviceInfoAccessLabel: deviceInfoAccessLabel ?? this.deviceInfoAccessLabel,
    locationAccessLabel: locationAccessLabel ?? this.locationAccessLabel,
    networkInfoAccessLabel:
        networkInfoAccessLabel ?? this.networkInfoAccessLabel,
    wakeLockAccessLabel: wakeLockAccessLabel ?? this.wakeLockAccessLabel,
    openAiCompatibleProvider:
        openAiCompatibleProvider ?? this.openAiCompatibleProvider,
    anthropicProvider: anthropicProvider ?? this.anthropicProvider,
    googleProvider: googleProvider ?? this.googleProvider,
    save: save ?? this.save,
    cancel: cancel ?? this.cancel,
    delete: delete ?? this.delete,
    edit: edit ?? this.edit,
    copy: copy ?? this.copy,
    confirmDeleteTitle: confirmDeleteTitle ?? this.confirmDeleteTitle,
    confirmDeleteMessage: confirmDeleteMessage ?? this.confirmDeleteMessage,
    cascadeDelete: cascadeDelete ?? this.cascadeDelete,
    requiredField: requiredField ?? this.requiredField,
    invalidNumber: invalidNumber ?? this.invalidNumber,
    invalidEndpoint: invalidEndpoint ?? this.invalidEndpoint,
    noSources: noSources ?? this.noSources,
    noModels: noModels ?? this.noModels,
    noAgents: noAgents ?? this.noAgents,
    selectModelFirst: selectModelFirst ?? this.selectModelFirst,
    delegationLabel: delegationLabel ?? this.delegationLabel,
    delegationGuidanceLabel:
        delegationGuidanceLabel ?? this.delegationGuidanceLabel,
    delegationGuidanceHint:
        delegationGuidanceHint ?? this.delegationGuidanceHint,
  );
}
