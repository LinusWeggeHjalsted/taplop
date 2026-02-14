using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class CameraControllerScript : MonoBehaviour
{
    public static CameraControllerScript Instance { get; private set; }
    private Camera mainCamera;
    public GameObject player;
    private Vector2 lastMousePosition;
    private bool isPointerOverUI = false;
    private bool isDragging = false;
    public bool draggedSinceLastCenter = false;

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
        else
        {
            Destroy(this.gameObject);
        }
        mainCamera = Camera.main;
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    void Start()
    {
        // Use GameReferences helper for clean lookup
        player = GameReferences.GetPlayer();
    }

    void Update()
    {
        // Refresh player reference if null (can happen on scene transitions)
        if (player == null)
        {
            player = GameReferences.GetPlayer();
        }

        if (EventSystem.current.IsPointerOverGameObject())
        {
            isPointerOverUI = true;
        }
        else
        {
            isPointerOverUI = false;
        }
        if (!isPointerOverUI)
        {
            if (Mouse.current != null && Mouse.current.rightButton.wasPressedThisFrame)
            {
                isDragging = true;
                lastMousePosition = Mouse.current.position.ReadValue();
            }
        }
        if (Mouse.current != null && Mouse.current.rightButton.isPressed && isDragging)
        {
            draggedSinceLastCenter = true;
            Vector2 currentMousePosition = Mouse.current.position.ReadValue();
            Vector2 mouseDelta = currentMousePosition - lastMousePosition;
            Vector3 worldDelta = ScreenToWorldDelta(mouseDelta);
            this.transform.position -= worldDelta;
            lastMousePosition = currentMousePosition;
        }
        if (Mouse.current != null && Mouse.current.rightButton.wasReleasedThisFrame)
        {
            isDragging = false;
        }
    }

    private Vector3 ScreenToWorldDelta(Vector2 screenDelta)
    {
        // camera reference might need to be updated
        if (mainCamera == null)
        {
            mainCamera = Camera.main;
        }
        Vector3 screenPoint1 = new Vector3(0, 0, Mathf.Abs(mainCamera.transform.position.z));
        Vector3 screenPoint2 = new Vector3(screenDelta.x, screenDelta.y, Mathf.Abs(mainCamera.transform.position.z));
        Vector3 worldPoint1 = mainCamera.ScreenToWorldPoint(screenPoint1);
        Vector3 worldPoint2 = mainCamera.ScreenToWorldPoint(screenPoint2);
        return worldPoint2 - worldPoint1;
    }

    public void MoveToPlayer()
    {
        // Use GameReferences helper for clean lookups
        GameObject characterUIObj = GameReferences.GetCharacterUI();
        GameObject canvas = GameReferences.GetCanvas();

        if (characterUIObj == null || canvas == null) return;
        Transform characterUI = characterUIObj.transform;
        Canvas canvasComponent = canvas.GetComponent<Canvas>();
        float canvasScaleFactor = canvasComponent.scaleFactor;
        float totalMenuWidth = 0;
        for (int i = 0; i < characterUI.childCount; i++)
        {
            Transform menu = characterUI.GetChild(i);
            if (menu != null && menu.gameObject.activeSelf)
            {
                RectTransform menuRect = menu.GetComponent<RectTransform>();
                if (menuRect != null)
                {
                    totalMenuWidth += menuRect.rect.width * canvasScaleFactor;
                }
            }
        }
        float halfMenuWidth = totalMenuWidth / 2f;
        if (mainCamera == null)
        {
            mainCamera = Camera.main;
        }

        // Refresh player reference if null
        if (player == null)
        {
            player = GameReferences.GetPlayer();
        }
        if (player == null) return; // Can't move to player if player doesn't exist

        Vector3 screenPointLeft = new Vector3(0, Screen.height / 2f, Mathf.Abs(mainCamera.transform.position.z));
        Vector3 screenPointRight = new Vector3(halfMenuWidth, Screen.height / 2f, Mathf.Abs(mainCamera.transform.position.z));
        Vector3 worldPointLeft = mainCamera.ScreenToWorldPoint(screenPointLeft);
        Vector3 worldPointRight = mainCamera.ScreenToWorldPoint(screenPointRight);
        float worldOffsetX = worldPointRight.x - worldPointLeft.x;
        Vector3 openMenuOffset = new Vector3(worldOffsetX, 0, 0);
        this.transform.position = player.transform.position - openMenuOffset;
        draggedSinceLastCenter = false;
    }
}
