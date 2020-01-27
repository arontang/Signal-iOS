//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit
import ZKGroup

public class GroupsV2Changes {

    // GroupsV2Changes has one responsibility: applying incremental
    // changes to group models. It should exactly mimic the behavior
    // of the service. Applying these "diffs" allow us to do two things:
    //
    // * Update groups without the burden of contacting the service.
    // * Stay aligned with service state... mostly.
    //
    // We can always deviate due to a bug or due to new "change actions"
    // that the local client doesn't know about. We're not versioning
    // the changes so if we introduce a breaking changes to the "change
    // actions" we'll need to roll out support for the new actions
    // before they go live.
    //
    // This method applies a single set of "change actions" to a group
    // model, thereby deriving a new group model whose revision is
    // exactly 1 higher.
    class func applyChangesToGroupModel(groupThread: TSGroupThread,
                                        changeActionsProto: GroupsProtoGroupChangeActions,
                                        changeActionsProtoData: Data,
                                        transaction: SDSAnyReadTransaction) throws -> ChangedGroupModel {
        let oldGroupModel = groupThread.groupModel
        let groupId = oldGroupModel.groupId
        let groupsVersion = oldGroupModel.groupsVersion
        guard groupsVersion == .V2 else {
            throw OWSAssertionError("Invalid groupsVersion: \(groupsVersion).")
        }
        // GroupsV2 TODO: Many change actions have author info,
        // e.g. addedByUserID.  We can safely assume that all
        // actions in the "change actions" have the same author.
        guard let changeAuthorUuidData = changeActionsProto.sourceUuid else {
            throw OWSAssertionError("Missing changeAuthorUuid.")
        }
        let changeAuthorUuid = changeAuthorUuidData.withUnsafeBytes {
            UUID(uuid: $0.bindMemory(to: uuid_t.self).first!)
        }
        guard changeActionsProto.hasVersion else {
            throw OWSAssertionError("Missing revision.")
        }
        let newRevision = changeActionsProto.version
        guard newRevision == oldGroupModel.groupV2Revision + 1 else {
            throw OWSAssertionError("Unexpected revision: \(newRevision) != \(oldGroupModel.groupV2Revision + 1).")
        }
        guard let groupSecretParamsData = oldGroupModel.groupSecretParamsData else {
            throw OWSAssertionError("Missing groupSecretParamsData.")
        }
        let groupParams = try GroupParams(groupModel: oldGroupModel)

        var newGroupName: String? = oldGroupModel.groupName
        let oldGroupMembership = oldGroupModel.groupMembership
        var groupMembershipBuilder = oldGroupMembership.asBuilder

        guard let oldGroupAccess = oldGroupModel.groupAccess else {
            throw OWSAssertionError("Missing oldGroupAccess.")
        }
        var newMemberAccess = oldGroupAccess.member
        var newAttributesAccess = oldGroupAccess.attributes

        // GroupsV2 TODO: after parsing, we should fill in profileKey if
        // not already in database. Also when learning of new groups.
        var newProfileKeys = [UUID: Data]()

        for action in changeActionsProto.addMembers {
            guard let member = action.added else {
                throw OWSAssertionError("Missing member.")
            }
            guard let userId = member.userID else {
                throw OWSAssertionError("Missing userID.")
            }
            guard let role = member.role else {
                throw OWSAssertionError("Missing role.")
            }
            guard let profileKey = member.profileKey else {
                throw OWSAssertionError("Missing profileKey.")
            }
            let uuid = try groupParams.uuid(forUserId: userId)
            let address = SignalServiceAddress(uuid: uuid)
            let isAdministrator = role == .administrator

            guard !oldGroupMembership.allUsers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            groupMembershipBuilder.replace(address, isAdministrator: isAdministrator, isPending: false)

            newProfileKeys[uuid] = profileKey
        }

        for action in changeActionsProto.deleteMembers {
            guard let userId = action.deletedUserID else {
                throw OWSAssertionError("Missing userID.")
            }
            let uuid = try groupParams.uuid(forUserId: userId)
            let address = SignalServiceAddress(uuid: uuid)

            guard oldGroupMembership.allMembers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            groupMembershipBuilder.remove(address)
        }

        for action in changeActionsProto.modifyMemberRoles {
            guard let userId = action.userID else {
                throw OWSAssertionError("Missing userID.")
            }
            guard let role = action.role else {
                throw OWSAssertionError("Missing role.")
            }
            let uuid = try groupParams.uuid(forUserId: userId)
            let address = SignalServiceAddress(uuid: uuid)
            let isAdministrator = role == .administrator

            guard oldGroupMembership.allMembers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            groupMembershipBuilder.replace(address, isAdministrator: isAdministrator, isPending: false)
        }

        for action in changeActionsProto.modifyMemberProfileKeys {
            guard let presentationData = action.presentation else {
                throw OWSAssertionError("Missing presentation.")
            }
            let presentation = try ProfileKeyCredentialPresentation(contents: [UInt8](presentationData))
            let uuidCiphertext = try presentation.getUuidCiphertext()
            let profileKeyCiphertext = try presentation.getProfileKeyCiphertext()
            let uuid = try groupParams.uuid(forUuidCiphertext: uuidCiphertext)
            let profileKey = try groupParams.profileKey(forProfileKeyCiphertext: profileKeyCiphertext)

            let address = SignalServiceAddress(uuid: uuid)
            guard oldGroupMembership.allMembers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            newProfileKeys[uuid] = profileKey
        }

        for action in changeActionsProto.addPendingMembers {
            guard let pendingMember = action.added else {
                throw OWSAssertionError("Missing pendingMember.")
            }
            guard let member = pendingMember.member else {
                throw OWSAssertionError("Missing member.")
            }
            guard let userId = member.userID else {
                throw OWSAssertionError("Missing userID.")
            }
            guard let role = member.role else {
                throw OWSAssertionError("Missing role.")
            }
            guard let profileKey = member.profileKey else {
                throw OWSAssertionError("Missing profileKey.")
            }
            let uuid = try groupParams.uuid(forUserId: userId)
            let address = SignalServiceAddress(uuid: uuid)
            let isAdministrator = role == .administrator

            guard !oldGroupMembership.allUsers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            groupMembershipBuilder.replace(address, isAdministrator: isAdministrator, isPending: true)

            newProfileKeys[uuid] = profileKey
        }

        for action in changeActionsProto.deletePendingMembers {
            guard let userId = action.deletedUserID else {
                throw OWSAssertionError("Missing userID.")
            }
            let uuid = try groupParams.uuid(forUserId: userId)
            let address = SignalServiceAddress(uuid: uuid)

            guard oldGroupMembership.allPendingMembers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            groupMembershipBuilder.remove(address)
        }

        for action in changeActionsProto.promotePendingMembers {
            guard let presentationData = action.presentation else {
                throw OWSAssertionError("Missing presentation.")
            }
            let presentation = try ProfileKeyCredentialPresentation(contents: [UInt8](presentationData))
            let uuidCiphertext = try presentation.getUuidCiphertext()
            let profileKeyCiphertext = try presentation.getProfileKeyCiphertext()
            let uuid = try groupParams.uuid(forUuidCiphertext: uuidCiphertext)
            let profileKey = try groupParams.profileKey(forProfileKeyCiphertext: profileKeyCiphertext)

            let address = SignalServiceAddress(uuid: uuid)
            guard oldGroupMembership.allPendingMembers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            guard !oldGroupMembership.allUsers.contains(address) else {
                throw OWSAssertionError("Invalid membership.")
            }
            let isAdministrator = oldGroupMembership.isAdministrator(address)
            groupMembershipBuilder.replace(address, isAdministrator: isAdministrator, isPending: false)

            newProfileKeys[uuid] = profileKey
        }

        if let action = changeActionsProto.modifyTitle {
            if let titleData = action.title {
                newGroupName = try groupParams.decryptString(titleData)
            } else {
                // Other client cleared the group title.
                newGroupName = nil
            }
        }

        if let action = changeActionsProto.modifyAvatar {
            // GroupsV2 TODO: Handle avatars.
            // GroupsProtoGroupChangeActionsModifyAvatarAction
        }

        if let action = changeActionsProto.modifyDisappearingMessagesTimer {
            // GroupsV2 TODO: Handle Dms.
            // GroupsProtoGroupChangeActionsModifyDisappearingMessagesTimerAction
        }

        if let action = changeActionsProto.modifyAttributesAccess {
            guard let protoAccess = action.attributesAccess else {
                throw OWSAssertionError("Missing access.")
            }
            newAttributesAccess = GroupAccess.groupV2Access(forProtoAccess: protoAccess)
        }

        if let action = changeActionsProto.modifyMemberAccess {
            guard let protoAccess = action.membersAccess else {
                throw OWSAssertionError("Missing access.")
            }
            newMemberAccess = GroupAccess.groupV2Access(forProtoAccess: protoAccess)
        }

        let newGroupMembership = groupMembershipBuilder.build()
        let newGroupAccess = GroupAccess(member: newMemberAccess, attributes: newAttributesAccess)
        // GroupsV2 TODO: Avatar.
        let avatarData: Data? = oldGroupModel.groupAvatarData

        let newGroupModel = try GroupManager.buildGroupModel(groupId: groupId,
                                                name: newGroupName,
                                                avatarData: avatarData,
                                                groupMembership: newGroupMembership,
                                                groupAccess: newGroupAccess,
                                                groupsVersion: groupsVersion,
                                                groupV2Revision: newRevision,
                                                groupSecretParamsData: groupSecretParamsData,
                                                transaction: transaction)
        return ChangedGroupModel(groupThread: groupThread,
                                 oldGroupModel: oldGroupModel,
                                 newGroupModel: newGroupModel,
                                 changeAuthorUuid: changeAuthorUuid,
                                 changeActionsProtoData: changeActionsProtoData)
    }
}