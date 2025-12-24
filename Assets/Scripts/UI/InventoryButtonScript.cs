using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class InventoryButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public Transform characterUI;
    public GameObject inventoryMenuPrefab;
    public GameObject inventoryMenu;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        // refresh canvas reference if it was destroyed
        if (canvas == null)
        {
            canvas = GameObject.Find("Canvas").transform;
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
            StartCoroutine(tooltipScript.SetText("Inventory [i]", ""));
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
        if (inventoryMenu == null)
        {
            inventoryMenu = Instantiate(inventoryMenuPrefab, characterUI);
        }
        else
        {
            Destroy(inventoryMenu);
        }
    }

    void Start()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        canvas = GameObject.Find("Canvas").transform;
        characterUI = GameObject.Find("Character UI").transform;
        inventoryMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Inventory Menu");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard != null)
        {
            if (keyboard.iKey.wasPressedThisFrame)
            {
                OnActivate();
            }
        }
    }
}
