module PostView exposing (Msg(..), PostView, ViewConfig, expandReplyComposer, handleEditorEventReceived, handleReplyCreated, init, markVisibleRepliesAsViewed, postNodeId, setup, teardown, update, view)

import Actor exposing (Actor)
import Avatar exposing (personAvatar)
import Browser.Navigation as Nav
import Color exposing (Color)
import Connection exposing (Connection)
import Dict exposing (Dict)
import File exposing (File)
import Flash
import Globals exposing (Globals)
import Group exposing (Group)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Icons
import Id exposing (Id)
import Json.Decode as Decode exposing (Decoder, field, maybe, string)
import Markdown
import Mutation.ClosePost as ClosePost
import Mutation.CreatePostReaction as CreatePostReaction
import Mutation.CreateReply as CreateReply
import Mutation.DeletePost as DeletePost
import Mutation.DeletePostReaction as DeletePostReaction
import Mutation.DismissPosts as DismissPosts
import Mutation.MarkAsRead as MarkAsRead
import Mutation.RecordReplyViews as RecordReplyViews
import Mutation.ReopenPost as ReopenPost
import Mutation.UpdatePost as UpdatePost
import Post exposing (Post)
import PostEditor exposing (PostEditor)
import Query.Replies
import RenderedHtml
import Reply exposing (Reply)
import ReplySet exposing (ReplySet)
import ReplyView exposing (ReplyView)
import Repo exposing (Repo)
import ResolvedAuthor exposing (ResolvedAuthor)
import ResolvedPostWithReplies exposing (ResolvedPostWithReplies)
import Route
import Route.Group
import Route.SpaceUser
import Scroll
import Session exposing (Session)
import Space exposing (Space)
import SpaceUser exposing (SpaceUser)
import Subscription.PostSubscription as PostSubscription
import Task exposing (Task)
import Time exposing (Posix, Zone)
import TimeWithZone exposing (TimeWithZone)
import ValidationError
import Vendor.Keys as Keys exposing (Modifier(..), enter, esc, onKeydown, preventDefault)
import View.Helpers exposing (onPassiveClick, setFocus, smartFormatTime, unsetFocus, viewIf, viewUnless)



-- MODEL


type alias PostView =
    { id : String
    , spaceId : String
    , replyViews : ReplySet
    , postedAt : Posix
    , editor : PostEditor
    , replyComposer : PostEditor
    , isChecked : Bool
    }


type alias Data =
    { post : Post
    , author : ResolvedAuthor
    , reactors : List SpaceUser
    }


resolveData : Repo -> PostView -> Maybe Data
resolveData repo postView =
    let
        maybePost =
            Repo.getPost postView.id repo
    in
    case maybePost of
        Just post ->
            Maybe.map3 Data
                (Just post)
                (ResolvedAuthor.resolve repo (Post.author post))
                (Just <| Repo.getSpaceUsers (Post.reactorIds post) repo)

        Nothing ->
            Nothing



-- LIFECYCLE


init : ResolvedPostWithReplies -> PostView
init resolvedPost =
    let
        postId =
            Post.id resolvedPost.post

        replies =
            resolvedPost.resolvedReplies
                |> Connection.map .reply
                |> Connection.toList

        replyViews =
            ReplySet.empty
                |> ReplySet.load (Post.spaceId resolvedPost.post) replies
    in
    PostView
        postId
        (Post.spaceId resolvedPost.post)
        replyViews
        (Post.postedAt resolvedPost.post)
        (PostEditor.init postId)
        (PostEditor.init postId)
        False


setup : Globals -> PostView -> Cmd Msg
setup globals postView =
    Cmd.batch
        [ PostSubscription.subscribe postView.id
        , markVisibleRepliesAsViewed globals postView
        ]


teardown : Globals -> PostView -> Cmd Msg
teardown globals postView =
    PostSubscription.unsubscribe postView.id



-- UPDATE


type Msg
    = NoOp
    | ReplyViewMsg Id ReplyView.Msg
    | ExpandReplyComposer
    | NewReplyBodyChanged String
    | NewReplyFileAdded File
    | NewReplyFileUploadProgress Id Int
    | NewReplyFileUploaded Id Id String
    | NewReplyFileUploadError Id
    | NewReplyBlurred
    | NewReplySubmit
    | NewReplyAndCloseSubmit
    | NewReplyEscaped
    | NewReplySubmitted (Result Session.Error ( Session, CreateReply.Response ))
    | PreviousRepliesRequested
    | PreviousRepliesFetched (Result Session.Error ( Session, Query.Replies.Response ))
    | ReplyViewsRecorded (Result Session.Error ( Session, RecordReplyViews.Response ))
    | SelectionToggled
    | DismissClicked
    | Dismissed (Result Session.Error ( Session, DismissPosts.Response ))
    | MoveToInboxClicked
    | PostMovedToInbox (Result Session.Error ( Session, MarkAsRead.Response ))
    | ExpandPostEditor
    | CollapsePostEditor
    | PostEditorBodyChanged String
    | PostEditorFileAdded File
    | PostEditorFileUploadProgress Id Int
    | PostEditorFileUploaded Id Id String
    | PostEditorFileUploadError Id
    | PostEditorSubmitted
    | PostUpdated (Result Session.Error ( Session, UpdatePost.Response ))
    | CreatePostReactionClicked
    | DeletePostReactionClicked
    | PostReactionCreated (Result Session.Error ( Session, CreatePostReaction.Response ))
    | PostReactionDeleted (Result Session.Error ( Session, DeletePostReaction.Response ))
    | ClosePostClicked
    | ReopenPostClicked
    | PostClosed (Result Session.Error ( Session, ClosePost.Response ))
    | PostReopened (Result Session.Error ( Session, ReopenPost.Response ))
    | DeletePostClicked
    | PostDeleted (Result Session.Error ( Session, DeletePost.Response ))
    | InternalLinkClicked String


update : Msg -> Globals -> PostView -> ( ( PostView, Cmd Msg ), Globals )
update msg globals postView =
    case msg of
        NoOp ->
            noCmd globals postView

        ReplyViewMsg replyId replyViewMsg ->
            case ReplySet.get replyId postView.replyViews of
                Just replyView ->
                    let
                        ( ( newReplyView, cmd ), newGlobals ) =
                            ReplyView.update replyViewMsg globals replyView
                    in
                    ( ( { postView | replyViews = ReplySet.update newReplyView postView.replyViews }
                      , Cmd.map (ReplyViewMsg replyId) cmd
                      )
                    , newGlobals
                    )

                Nothing ->
                    ( ( postView, Cmd.none ), globals )

        ExpandReplyComposer ->
            expandReplyComposer globals postView

        NewReplyBodyChanged val ->
            let
                newReplyComposer =
                    PostEditor.setBody val postView.replyComposer
            in
            ( ( { postView | replyComposer = newReplyComposer }
              , PostEditor.saveLocal newReplyComposer
              )
            , globals
            )

        NewReplyFileAdded file ->
            noCmd globals { postView | replyComposer = PostEditor.addFile file postView.replyComposer }

        NewReplyFileUploadProgress clientId percentage ->
            noCmd globals { postView | replyComposer = PostEditor.setFileUploadPercentage clientId percentage postView.replyComposer }

        NewReplyFileUploaded clientId fileId url ->
            let
                newReplyComposer =
                    postView.replyComposer
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newReplyComposer
                        |> PostEditor.insertFileLink fileId
            in
            ( ( { postView | replyComposer = newReplyComposer }, cmd ), globals )

        NewReplyFileUploadError clientId ->
            noCmd globals { postView | replyComposer = PostEditor.setFileState clientId File.UploadError postView.replyComposer }

        NewReplySubmit ->
            let
                newPostView =
                    { postView | replyComposer = PostEditor.setToSubmitting postView.replyComposer }

                body =
                    PostEditor.getBody postView.replyComposer

                cmd =
                    globals.session
                        |> CreateReply.request postView.spaceId postView.id body (PostEditor.getUploadIds postView.replyComposer)
                        |> Task.attempt NewReplySubmitted
            in
            ( ( newPostView, cmd ), globals )

        NewReplyAndCloseSubmit ->
            let
                newPostView =
                    { postView | replyComposer = PostEditor.setToSubmitting postView.replyComposer }

                body =
                    PostEditor.getBody postView.replyComposer

                replyCmd =
                    globals.session
                        |> CreateReply.request postView.spaceId postView.id body (PostEditor.getUploadIds postView.replyComposer)
                        |> Task.attempt NewReplySubmitted

                closeCmd =
                    globals.session
                        |> ClosePost.request postView.spaceId postView.id
                        |> Task.attempt PostClosed
            in
            ( ( newPostView, Cmd.batch [ replyCmd, closeCmd ] ), globals )

        NewReplySubmitted (Ok ( newSession, reply )) ->
            let
                ( newReplyComposer, cmd ) =
                    postView.replyComposer
                        |> PostEditor.reset

                newPostView =
                    { postView | replyComposer = newReplyComposer }
            in
            ( ( newPostView
              , Cmd.batch
                    [ setFocus (PostEditor.getTextareaId postView.replyComposer) NoOp
                    , cmd
                    ]
              )
            , { globals | session = newSession }
            )

        NewReplySubmitted (Err Session.Expired) ->
            redirectToLogin globals postView

        NewReplySubmitted (Err _) ->
            noCmd globals postView

        NewReplyEscaped ->
            if PostEditor.getBody postView.replyComposer == "" then
                ( ( { postView | replyComposer = PostEditor.collapse postView.replyComposer }
                  , unsetFocus (PostEditor.getTextareaId postView.replyComposer) NoOp
                  )
                , globals
                )

            else
                noCmd globals postView

        NewReplyBlurred ->
            noCmd globals postView

        PreviousRepliesRequested ->
            case ReplySet.firstPostedAt postView.replyViews of
                Just postedAt ->
                    let
                        variables =
                            Query.Replies.variables postView.spaceId postView.id 10 postedAt

                        cmd =
                            globals.session
                                |> Query.Replies.request variables
                                |> Task.attempt PreviousRepliesFetched
                    in
                    ( ( postView, cmd ), globals )

                Nothing ->
                    noCmd globals postView

        PreviousRepliesFetched (Ok ( newSession, resp )) ->
            let
                replies =
                    resp.resolvedReplies
                        |> Connection.map .reply
                        |> Connection.toList

                newReplyViews =
                    ReplySet.addPrev postView.spaceId replies postView.replyViews

                newGlobals =
                    { globals
                        | session = newSession
                        , repo = Repo.union resp.repo globals.repo
                    }

                newPostView =
                    { postView | replyViews = newReplyViews }

                viewCmd =
                    markVisibleRepliesAsViewed newGlobals newPostView
            in
            ( ( newPostView, viewCmd ), newGlobals )

        PreviousRepliesFetched (Err Session.Expired) ->
            redirectToLogin globals postView

        PreviousRepliesFetched (Err _) ->
            noCmd globals postView

        ReplyViewsRecorded (Ok ( newSession, _ )) ->
            noCmd { globals | session = newSession } postView

        ReplyViewsRecorded (Err Session.Expired) ->
            redirectToLogin globals postView

        ReplyViewsRecorded (Err _) ->
            noCmd globals postView

        SelectionToggled ->
            ( ( { postView | isChecked = not postView.isChecked }
              , markVisibleRepliesAsViewed globals postView
              )
            , globals
            )

        DismissClicked ->
            let
                cmd =
                    globals.session
                        |> DismissPosts.request postView.spaceId [ postView.id ]
                        |> Task.attempt Dismissed
            in
            ( ( postView, cmd ), globals )

        Dismissed (Ok ( newSession, _ )) ->
            ( ( postView, Cmd.none )
            , { globals
                | session = newSession
                , flash = Flash.set Flash.Notice "Dismissed from inbox" 3000 globals.flash
              }
            )

        Dismissed (Err Session.Expired) ->
            redirectToLogin globals postView

        Dismissed (Err _) ->
            noCmd globals postView

        MoveToInboxClicked ->
            let
                cmd =
                    globals.session
                        |> MarkAsRead.request postView.spaceId [ postView.id ]
                        |> Task.attempt PostMovedToInbox
            in
            ( ( postView, cmd ), globals )

        PostMovedToInbox (Ok ( newSession, _ )) ->
            ( ( postView, Cmd.none )
            , { globals
                | session = newSession
                , flash = Flash.set Flash.Notice "Moved to inbox" 3000 globals.flash
              }
            )

        PostMovedToInbox (Err Session.Expired) ->
            redirectToLogin globals postView

        PostMovedToInbox (Err _) ->
            noCmd globals postView

        ExpandPostEditor ->
            case resolveData globals.repo postView of
                Just data ->
                    let
                        nodeId =
                            PostEditor.getTextareaId postView.editor

                        newPostEditor =
                            postView.editor
                                |> PostEditor.expand
                                |> PostEditor.setBody (Post.body data.post)
                                |> PostEditor.setFiles (Post.files data.post)
                                |> PostEditor.clearErrors

                        cmd =
                            Cmd.batch
                                [ setFocus nodeId NoOp
                                ]
                    in
                    ( ( { postView | editor = newPostEditor }, cmd ), globals )

                Nothing ->
                    noCmd globals postView

        CollapsePostEditor ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.collapse
            in
            ( ( { postView | editor = newPostEditor }, Cmd.none ), globals )

        PostEditorBodyChanged val ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setBody val
            in
            noCmd globals { postView | editor = newPostEditor }

        PostEditorFileAdded file ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.addFile file
            in
            noCmd globals { postView | editor = newPostEditor }

        PostEditorFileUploadProgress clientId percentage ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setFileUploadPercentage clientId percentage
            in
            noCmd globals { postView | editor = newPostEditor }

        PostEditorFileUploaded clientId fileId url ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setFileState clientId (File.Uploaded fileId url)

                cmd =
                    newPostEditor
                        |> PostEditor.insertFileLink fileId
            in
            ( ( { postView | editor = newPostEditor }, cmd ), globals )

        PostEditorFileUploadError clientId ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setFileState clientId File.UploadError
            in
            noCmd globals { postView | editor = newPostEditor }

        PostEditorSubmitted ->
            let
                cmd =
                    globals.session
                        |> UpdatePost.request postView.spaceId postView.id (PostEditor.getBody postView.editor)
                        |> Task.attempt PostUpdated

                newPostEditor =
                    postView.editor
                        |> PostEditor.setToSubmitting
                        |> PostEditor.clearErrors
            in
            ( ( { postView | editor = newPostEditor }, cmd ), globals )

        PostUpdated (Ok ( newSession, UpdatePost.Success post )) ->
            let
                newGlobals =
                    { globals | session = newSession, repo = Repo.setPost post globals.repo }

                newPostEditor =
                    postView.editor
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.collapse
            in
            ( ( { postView | editor = newPostEditor }, Cmd.none ), newGlobals )

        PostUpdated (Ok ( newSession, UpdatePost.Invalid errors )) ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.setErrors errors
            in
            ( ( { postView | editor = newPostEditor }, Cmd.none ), globals )

        PostUpdated (Err Session.Expired) ->
            redirectToLogin globals postView

        PostUpdated (Err _) ->
            let
                newPostEditor =
                    postView.editor
                        |> PostEditor.setNotSubmitting
            in
            ( ( { postView | editor = newPostEditor }, Cmd.none ), globals )

        CreatePostReactionClicked ->
            let
                variables =
                    CreatePostReaction.variables postView.spaceId postView.id

                cmd =
                    globals.session
                        |> CreatePostReaction.request variables
                        |> Task.attempt PostReactionCreated
            in
            ( ( postView, cmd ), globals )

        PostReactionCreated (Ok ( newSession, CreatePostReaction.Success post )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setPost post globals.repo, session = newSession }
            in
            ( ( postView, Cmd.none ), newGlobals )

        PostReactionCreated (Err Session.Expired) ->
            redirectToLogin globals postView

        PostReactionCreated _ ->
            ( ( postView, Cmd.none ), globals )

        DeletePostReactionClicked ->
            let
                variables =
                    DeletePostReaction.variables postView.spaceId postView.id

                cmd =
                    globals.session
                        |> DeletePostReaction.request variables
                        |> Task.attempt PostReactionDeleted
            in
            ( ( postView, cmd ), globals )

        PostReactionDeleted (Ok ( newSession, DeletePostReaction.Success post )) ->
            let
                newGlobals =
                    { globals | repo = Repo.setPost post globals.repo, session = newSession }
            in
            ( ( postView, Cmd.none ), newGlobals )

        PostReactionDeleted (Err Session.Expired) ->
            redirectToLogin globals postView

        PostReactionDeleted _ ->
            ( ( postView, Cmd.none ), globals )

        ClosePostClicked ->
            let
                cmd =
                    globals.session
                        |> ClosePost.request postView.spaceId postView.id
                        |> Task.attempt PostClosed
            in
            ( ( { postView | replyComposer = PostEditor.setToSubmitting postView.replyComposer }, cmd ), globals )

        ReopenPostClicked ->
            let
                cmd =
                    globals.session
                        |> ReopenPost.request postView.spaceId postView.id
                        |> Task.attempt PostReopened
            in
            ( ( { postView | replyComposer = PostEditor.setToSubmitting postView.replyComposer }, cmd ), globals )

        DeletePostClicked ->
            let
                cmd =
                    globals.session
                        |> DeletePost.request (DeletePost.variables postView.spaceId postView.id)
                        |> Task.attempt PostDeleted
            in
            ( ( { postView | editor = PostEditor.setToSubmitting postView.editor }, cmd ), globals )

        PostClosed (Ok ( newSession, ClosePost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post

                newReplyComposer =
                    postView.replyComposer
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.collapse
            in
            ( ( { postView | replyComposer = newReplyComposer }, Cmd.none )
            , { globals | repo = newRepo, session = newSession }
            )

        PostClosed (Ok ( newSession, ClosePost.Invalid errors )) ->
            ( ( { postView | replyComposer = PostEditor.setNotSubmitting postView.replyComposer }, Cmd.none )
            , { globals | session = newSession }
            )

        PostClosed (Err Session.Expired) ->
            redirectToLogin globals postView

        PostClosed (Err _) ->
            noCmd globals postView

        PostReopened (Ok ( newSession, ReopenPost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post

                newReplyComposer =
                    postView.replyComposer
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.expand

                cmd =
                    setFocus (PostEditor.getTextareaId newReplyComposer) NoOp
            in
            ( ( { postView | replyComposer = newReplyComposer }, cmd )
            , { globals | repo = newRepo, session = newSession }
            )

        PostReopened (Ok ( newSession, ReopenPost.Invalid errors )) ->
            ( ( { postView | replyComposer = PostEditor.setNotSubmitting postView.replyComposer }, Cmd.none )
            , { globals | session = newSession }
            )

        PostReopened (Err Session.Expired) ->
            redirectToLogin globals postView

        PostReopened (Err _) ->
            noCmd globals postView

        PostDeleted (Ok ( newSession, DeletePost.Success post )) ->
            let
                newRepo =
                    globals.repo
                        |> Repo.setPost post

                newPostEditor =
                    postView.editor
                        |> PostEditor.setNotSubmitting
                        |> PostEditor.collapse
            in
            ( ( { postView | editor = newPostEditor }, Cmd.none )
            , { globals | repo = newRepo, session = newSession }
            )

        PostDeleted (Ok ( newSession, DeletePost.Invalid errors )) ->
            ( ( { postView | editor = PostEditor.setNotSubmitting postView.editor }, Cmd.none )
            , { globals | session = newSession }
            )

        PostDeleted (Err Session.Expired) ->
            redirectToLogin globals postView

        PostDeleted (Err _) ->
            noCmd globals postView

        InternalLinkClicked pathname ->
            ( ( postView, Nav.pushUrl globals.navKey pathname ), globals )


noCmd : Globals -> PostView -> ( ( PostView, Cmd Msg ), Globals )
noCmd globals postView =
    ( ( postView, Cmd.none ), globals )


redirectToLogin : Globals -> PostView -> ( ( PostView, Cmd Msg ), Globals )
redirectToLogin globals postView =
    ( ( postView, Route.toLogin ), globals )


markVisibleRepliesAsViewed : Globals -> PostView -> Cmd Msg
markVisibleRepliesAsViewed globals postView =
    -- let
    --     ( replies, _ ) =
    --         visibleReplies globals.repo postView.replyIds
    --
    --     unviewedReplyIds =
    --         replies
    --             |> List.filter (\reply -> not (Reply.hasViewed reply))
    --             |> List.map Reply.id
    -- in
    -- if List.length unviewedReplyIds > 0 then
    --     globals.session
    --         |> RecordReplyViews.request postView.spaceId unviewedReplyIds
    --         |> Task.attempt ReplyViewsRecorded
    --
    -- else
    Cmd.none


expandReplyComposer : Globals -> PostView -> ( ( PostView, Cmd Msg ), Globals )
expandReplyComposer globals postView =
    let
        cmd =
            Cmd.batch
                [ setFocus (PostEditor.getTextareaId postView.replyComposer) NoOp
                , markVisibleRepliesAsViewed globals postView
                ]

        newPostView =
            { postView | replyComposer = PostEditor.expand postView.replyComposer }
    in
    ( ( newPostView, cmd ), globals )



-- EVENT HANDLERS


handleReplyCreated : Reply -> PostView -> ( PostView, Cmd Msg )
handleReplyCreated reply postView =
    -- if Reply.postId reply == postView.id then
    --     ( { postView | replyIds = Connection.append identity (Reply.id reply) postView.replyIds }, Cmd.none )
    --
    -- else
    ( postView, Cmd.none )


handleEditorEventReceived : Decode.Value -> PostView -> PostView
handleEditorEventReceived value postView =
    case PostEditor.decodeEvent value of
        PostEditor.LocalDataFetched id body ->
            if id == PostEditor.getId postView.replyComposer then
                let
                    newReplyComposer =
                        PostEditor.setBody body postView.replyComposer
                in
                { postView | replyComposer = newReplyComposer }

            else
                postView

        PostEditor.Unknown ->
            postView



-- VIEWS


type alias ViewConfig =
    { globals : Globals
    , space : Space
    , currentUser : SpaceUser
    , now : TimeWithZone
    , spaceUsers : List SpaceUser
    , groups : List Group
    , showGroups : Bool
    }


view : ViewConfig -> PostView -> Html Msg
view config postView =
    case resolveData config.globals.repo postView of
        Just data ->
            resolvedView config postView data

        Nothing ->
            text "Something went wrong."


resolvedView : ViewConfig -> PostView -> Data -> Html Msg
resolvedView config postView data =
    div [ id (postNodeId postView.id), class "flex" ]
        [ div [ class "flex-no-shrink mr-3" ] [ Avatar.fromConfig (ResolvedAuthor.avatarConfig Avatar.Medium data.author) ]
        , div [ class "flex-grow min-w-0 leading-normal" ]
            [ div [ class "pb-1/2 flex items-center flex-wrap" ]
                [ div []
                    [ postAuthorName config.space postView.id data.author
                    , viewIf (Post.isPrivate data.post) <|
                        span [ class "mr-2 inline-block" ] [ Icons.lock ]
                    , a
                        [ Route.href <| Route.Post (Space.slug config.space) postView.id
                        , class "no-underline whitespace-no-wrap"
                        , rel "tooltip"
                        , title "Expand post"
                        ]
                        [ View.Helpers.timeTag config.now (TimeWithZone.setPosix (Post.postedAt data.post) config.now) [ class "mr-3 text-sm text-dusty-blue" ] ]
                    , viewIf (not (PostEditor.isExpanded postView.editor) && Post.canEdit data.post) <|
                        button
                            [ class "mr-3 text-sm text-dusty-blue"
                            , onClick ExpandPostEditor
                            ]
                            [ text "Edit" ]
                    ]
                , inboxButton data.post
                , viewIf (Post.state data.post == Post.Closed) (reopenButton data.post)
                ]
            , viewIf config.showGroups <|
                groupsLabel config.space (Repo.getGroups (Post.groupIds data.post) config.globals.repo)
            , viewUnless (PostEditor.isExpanded postView.editor) <|
                bodyView config.space data.post
            , viewIf (PostEditor.isExpanded postView.editor) <|
                editorView config postView.editor
            , div [ class "pb-2 flex items-start" ]
                [ postReactionButton data.post data.reactors
                , replyButtonView config postView data
                ]
            , div [ class "relative" ]
                [ repliesView config postView data
                , replyComposerView config postView data
                ]
            ]
        ]



-- PRIVATE POST VIEW FUNCTIONS


inboxButton : Post -> Html Msg
inboxButton post =
    let
        addButton =
            button
                [ class "mr-3 flex tooltip tooltip-bottom no-outline"
                , onClick MoveToInboxClicked
                , attribute "data-tooltip" "Move to inbox"
                ]
                [ Icons.inbox Icons.Off
                ]

        removeButton =
            button
                [ class "mr-3 flex tooltip tooltip-bottom no-outline text-sm text-green font-bold"
                , onClick DismissClicked
                , attribute "data-tooltip" "Dismiss from inbox"
                ]
                [ span [ class "inline-block" ] [ Icons.inbox Icons.On ]
                ]
    in
    case Post.inboxState post of
        Post.Excluded ->
            addButton

        Post.Dismissed ->
            addButton

        Post.Read ->
            removeButton

        Post.Unread ->
            removeButton


reopenButton : Post -> Html Msg
reopenButton post =
    button
        [ class "tooltip tooltip-bottom mr-3"
        , attribute "data-tooltip" "Reopen conversation"
        , onClick ReopenPostClicked
        ]
        [ Icons.closedSmall ]


postAuthorName : Space -> Id -> ResolvedAuthor -> Html Msg
postAuthorName space postId author =
    let
        route =
            case ResolvedAuthor.actor author of
                Actor.User user ->
                    Route.SpaceUser (Route.SpaceUser.init (Space.slug space) (SpaceUser.handle user))

                _ ->
                    Route.Post (Space.slug space) postId
    in
    a
        [ Route.href route
        , class "no-underline whitespace-no-wrap"
        ]
        [ span [ class "font-bold text-dusty-blue-darkest mr-2" ] [ text <| ResolvedAuthor.displayName author ]
        , span [ class "ml-2 text-dusty-blue hidden" ] [ text <| "@" ++ ResolvedAuthor.handle author ]
        ]


groupsLabel : Space -> List Group -> Html Msg
groupsLabel space groups =
    let
        groupLink group =
            a
                [ Route.href (Route.Group (Route.Group.init (Space.slug space) (Group.name group)))
                , class "mr-1 no-underline text-dusty-blue-dark whitespace-no-wrap"
                ]
                [ text ("#" ++ Group.name group) ]

        groupLinks =
            List.map groupLink groups
    in
    if List.isEmpty groups then
        text ""

    else
        div [ class "pb-1 mr-3 text-base text-dusty-blue" ]
            [ text ""
            , span [] groupLinks
            ]


bodyView : Space -> Post -> Html Msg
bodyView space post =
    div []
        [ div [ class "markdown pb-3/2" ]
            [ RenderedHtml.node
                { html = Post.bodyHtml post
                , onInternalLinkClicked = InternalLinkClicked
                }
            ]
        , staticFilesView (Post.files post)
        ]


editorView : ViewConfig -> PostEditor -> Html Msg
editorView viewConfig editor =
    let
        config =
            { editor = editor
            , spaceId = Space.id viewConfig.space
            , spaceUsers = viewConfig.spaceUsers
            , groups = viewConfig.groups
            , onFileAdded = PostEditorFileAdded
            , onFileUploadProgress = PostEditorFileUploadProgress
            , onFileUploaded = PostEditorFileUploaded
            , onFileUploadError = PostEditorFileUploadError
            , classList = [ ( "tribute-pin-t", True ) ]
            }
    in
    PostEditor.wrapper config
        [ label [ class "composer my-2 p-3 bg-grey-light rounded-xl" ]
            [ textarea
                [ id (PostEditor.getTextareaId editor)
                , class "w-full no-outline text-dusty-blue-darkest bg-transparent resize-none leading-normal"
                , placeholder "Edit post..."
                , onInput PostEditorBodyChanged
                , readonly (PostEditor.isSubmitting editor)
                , value (PostEditor.getBody editor)
                , onKeydown preventDefault
                    [ ( [ Meta ], enter, \event -> PostEditorSubmitted )
                    ]
                ]
                []
            , ValidationError.prefixedErrorView "body" "Body" (PostEditor.getErrors editor)
            , PostEditor.filesView editor
            , div [ class "flex" ]
                [ button
                    [ class "mr-2 btn btn-grey-outline btn-sm"
                    , onClick DeletePostClicked
                    ]
                    [ text "Delete post" ]
                , div [ class "flex-grow flex justify-end" ]
                    [ button
                        [ class "mr-2 btn btn-grey-outline btn-sm"
                        , onClick CollapsePostEditor
                        ]
                        [ text "Cancel" ]
                    , button
                        [ class "btn btn-blue btn-sm"
                        , onClick PostEditorSubmitted
                        , disabled (PostEditor.isUnsubmittable editor)
                        ]
                        [ text "Update post" ]
                    ]
                ]
            ]
        ]



-- PRIVATE REPLY VIEW FUNCTIONS


repliesView : ViewConfig -> PostView -> Data -> Html Msg
repliesView config postView data =
    viewUnless (ReplySet.isEmpty postView.replyViews) <|
        div []
            [ button
                [ class "flex items-center mt-2 mb-4 text-dusty-blue no-underline whitespace-no-wrap"
                , onClick PreviousRepliesRequested
                ]
                [ text "Load more..."
                ]
            , div []
                (ReplySet.map
                    (\replyView ->
                        ReplyView.view config replyView
                            |> Html.map (ReplyViewMsg replyView.id)
                    )
                    postView.replyViews
                )
            ]


replyComposerView : ViewConfig -> PostView -> Data -> Html Msg
replyComposerView viewConfig postView data =
    let
        post =
            data.post
    in
    if PostEditor.isExpanded postView.replyComposer then
        expandedReplyComposerView viewConfig postView.replyComposer

    else
        replyPromptView viewConfig postView data


expandedReplyComposerView : ViewConfig -> PostEditor -> Html Msg
expandedReplyComposerView viewConfig editor =
    let
        config =
            { editor = editor
            , spaceId = Space.id viewConfig.space
            , spaceUsers = viewConfig.spaceUsers
            , groups = viewConfig.groups
            , onFileAdded = NewReplyFileAdded
            , onFileUploadProgress = NewReplyFileUploadProgress
            , onFileUploaded = NewReplyFileUploaded
            , onFileUploadError = NewReplyFileUploadError
            , classList = [ ( "tribute-pin-t", True ) ]
            }
    in
    div [ class "pt-3 sticky pin-b bg-white text-md z-20" ]
        [ PostEditor.wrapper config
            [ div [ class "composer p-0" ]
                [ label [ class "flex" ]
                    [ div [ class "flex-no-shrink mr-2 pt-1 z-10" ] [ SpaceUser.avatar Avatar.Small viewConfig.currentUser ]
                    , div [ class "flex-grow -ml-6 pl-6 pr-3 py-3 bg-grey-light w-full rounded-xl" ]
                        [ textarea
                            [ id (PostEditor.getTextareaId editor)
                            , class "p-1 w-full h-10 no-outline bg-transparent text-dusty-blue-darkest resize-none leading-normal"
                            , placeholder "Write a reply..."
                            , onInput NewReplyBodyChanged
                            , onKeydown preventDefault
                                [ ( [ Meta ], enter, \event -> NewReplySubmit )
                                , ( [ Shift, Meta ], enter, \event -> NewReplyAndCloseSubmit )
                                , ( [], esc, \event -> NewReplyEscaped )
                                ]
                            , onBlur NewReplyBlurred
                            , value (PostEditor.getBody editor)
                            , readonly (PostEditor.isSubmitting editor)
                            ]
                            []
                        , PostEditor.filesView editor
                        , div [ class "flex items-baseline justify-end" ]
                            [ viewIf (PostEditor.isUnsubmittable editor) <|
                                button
                                    [ class "mr-2 btn btn-grey-outline btn-sm"
                                    , onClick ClosePostClicked
                                    ]
                                    [ text "Resolve" ]
                            , viewUnless (PostEditor.isUnsubmittable editor) <|
                                button
                                    [ class "mr-2 btn btn-grey-outline btn-sm"
                                    , onClick NewReplyAndCloseSubmit
                                    ]
                                    [ text "Send & Resolve" ]
                            , button
                                [ class "btn btn-blue btn-sm"
                                , onClick NewReplySubmit
                                , disabled (PostEditor.isUnsubmittable editor)
                                ]
                                [ text "Send" ]
                            ]
                        ]
                    ]
                ]
            ]
        ]


replyPromptView : ViewConfig -> PostView -> Data -> Html Msg
replyPromptView config postView data =
    let
        ( prompt, msg ) =
            case Post.state data.post of
                Post.Open ->
                    ( "Reply or resolve...", ExpandReplyComposer )

                Post.Closed ->
                    ( "Reopen conversation...", ReopenPostClicked )

                Post.Deleted ->
                    ( "", NoOp )
    in
    if not (ReplySet.isEmpty postView.replyViews) then
        button [ class "flex my-4 items-center text-md", onClick msg ]
            [ div [ class "flex-no-shrink mr-3" ] [ SpaceUser.avatar Avatar.Small config.currentUser ]
            , div [ class "flex-grow leading-semi-loose text-dusty-blue" ]
                [ text prompt
                ]
            ]

    else
        text ""


replyButtonView : ViewConfig -> PostView -> Data -> Html Msg
replyButtonView config postView data =
    if Post.state data.post == Post.Open then
        button
            [ class "tooltip tooltip-bottom"
            , onClick ExpandReplyComposer
            , attribute "data-tooltip" "Reply or Resolve"
            ]
            [ Icons.reply ]

    else
        button
            [ class "tooltip tooltip-bottom"
            , onClick ReopenPostClicked
            , attribute "data-tooltip" "Reopen"
            ]
            [ Icons.reply ]


staticFilesView : List File -> Html msg
staticFilesView files =
    viewUnless (List.isEmpty files) <|
        div [ class "flex flex-wrap pb-2" ] <|
            List.map staticFileView files


staticFileView : File -> Html msg
staticFileView file =
    case File.getState file of
        File.Uploaded id url ->
            a
                [ href url
                , target "_blank"
                , class "flex flex-none items-center mr-4 pb-1 no-underline text-dusty-blue hover:text-blue"
                , rel "tooltip"
                , title "Download file"
                ]
                [ div [ class "mr-2" ] [ File.icon Color.DustyBlue file ]
                , div [ class "text-sm font-bold truncate" ] [ text <| "Download " ++ File.getName file ]
                ]

        _ ->
            text ""



-- REACTIONS


postReactionButton : Post -> List SpaceUser -> Html Msg
postReactionButton post reactors =
    let
        flyoutLabel =
            if List.isEmpty reactors then
                "Acknowledge"

            else
                "Acknowledged by"
    in
    if Post.hasReacted post then
        button
            [ class "flex relative items-center mr-6 no-outline react-button"
            , onClick DeletePostReactionClicked
            ]
            [ Icons.thumbs Icons.On
            , viewIf (Post.reactionCount post > 0) <|
                div
                    [ class "ml-1 text-green font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Post.reactionCount post) ]
            , div [ classList [ ( "reactors", True ), ( "no-reactors", List.isEmpty reactors ) ] ]
                [ div [ class "text-xs font-bold text-white" ] [ text flyoutLabel ]
                , viewUnless (List.isEmpty reactors) <|
                    div [ class "mt-1" ] (List.map reactorView reactors)
                ]
            ]

    else
        button
            [ class "flex relative items-center mr-6 no-outline react-button"
            , onClick CreatePostReactionClicked
            ]
            [ Icons.thumbs Icons.Off
            , viewIf (Post.reactionCount post > 0) <|
                div
                    [ class "ml-1 text-dusty-blue font-bold text-sm"
                    ]
                    [ text <| String.fromInt (Post.reactionCount post) ]
            , div [ classList [ ( "reactors", True ), ( "no-reactors", List.isEmpty reactors ) ] ]
                [ div [ class "text-xs font-bold text-white" ] [ text flyoutLabel ]
                , viewUnless (List.isEmpty reactors) <|
                    div [ class "mt-1" ] (List.map reactorView reactors)
                ]
            ]


reactorView : SpaceUser -> Html Msg
reactorView user =
    div
        [ class "flex items-center pr-4 mb-px no-underline text-white"
        ]
        [ div [ class "flex-no-shrink mr-2" ] [ SpaceUser.avatar Avatar.Tiny user ]
        , div [ class "flex-grow text-sm truncate" ] [ text <| SpaceUser.displayName user ]
        ]



-- UTILS


postNodeId : String -> String
postNodeId postId =
    "post-" ++ postId


replyNodeId : String -> String
replyNodeId replyId =
    "reply-" ++ replyId


replyComposerId : String -> String
replyComposerId postId =
    "reply-composer-" ++ postId


visibleReplies : Repo -> Connection Id -> ( List Reply, Bool )
visibleReplies repo replyIds =
    let
        replies =
            repo
                |> Repo.getReplies (Connection.toList replyIds)
                |> List.filter Reply.notDeleted

        hasPreviousPage =
            Connection.hasPreviousPage replyIds
    in
    ( replies, hasPreviousPage )
