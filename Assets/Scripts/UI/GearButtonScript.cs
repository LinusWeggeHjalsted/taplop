using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class GearButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public Transform characterUI;
    public GameObject gearMenuPrefab;
    public GameObject gearMenu;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        // refresh canvas reference if it was destroyed
        if (canvas == null)
        {
            canvas = GameReferences.GetCanvasTransform();
        }
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopLeftPosition = buttonCorners[1];
        Transform tooltipTransform = canvas.Find("Tooltip");
        if (tooltipTransform != null)
        {
            tooltip = tooltipTransform.gameObject;
        }
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, canvas);
            tooltip.name = "Tooltip";
            tooltip.transform.SetAsLastSibling();
        }
        if (tooltip != null)
        {
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(0, 0);
            tooltipRectTransform.position = buttonTopLeftPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Gear [o]", ""));
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound();
        if (gearMenu == null)
        {
            gearMenu = Instantiate(gearMenuPrefab, characterUI);
        }
        else
        {
            DestroyImmediate(gearMenu);
        }
        if (!CameraControllerScript.Instance.draggedSinceLastCenter)
        {
            CameraControllerScript.Instance.MoveToPlayer();
        }
    }

    void Awake()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        gearMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Gear Menu");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
        characterUI = GameReferences.GetCharacterUI().transform;
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.oKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
