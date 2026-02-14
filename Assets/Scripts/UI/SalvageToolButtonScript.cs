using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;

public class SalvageToolButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public static SalvageToolButtonScript Instance { get; private set; }
    public RectTransform buttonRectTransform;
    public Button button;
    public GameObject highlight;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    private bool _salvageToolIsActive = false;
    public bool salvageToolIsActive 
    {
        get
        {
            return _salvageToolIsActive;
        }
        set
        {
            if (value == true)
            {
                highlight.SetActive(true);
            }
            else
            {
                highlight.SetActive(false);
            }
            _salvageToolIsActive = value;
        }
    }

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
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        highlight = this.transform.Find("Highlight").gameObject;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopRightPosition = buttonCorners[2];
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
            tooltipRectTransform.pivot = new Vector2(0, 1f);
            tooltipRectTransform.position = buttonTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Salvage [hold shift]", ""));
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
        if (salvageToolIsActive)
        {
            salvageToolIsActive = false;
        }
        else
        {
            salvageToolIsActive = true;
        }
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;
        if (keyboard.leftShiftKey.wasPressedThisFrame || keyboard.rightShiftKey.wasPressedThisFrame)
        {
            highlight.SetActive(true);
        }
        if (keyboard.leftShiftKey.wasReleasedThisFrame || keyboard.rightShiftKey.wasReleasedThisFrame)
        {
            if (!salvageToolIsActive)
            {
                highlight.SetActive(false);
            }
        }
    }
}
