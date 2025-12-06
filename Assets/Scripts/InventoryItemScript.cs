using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class InventoryItemScript : MonoBehaviour, IBeginDragHandler, IDragHandler, IEndDragHandler, IPointerEnterHandler, IPointerExitHandler, IPointerClickHandler
{
    public GameObject item;
    public Transform currentParent;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public GameObject contextMenuPrefab;
    public GameObject contextMenu;
    public string itemType
    {
        get
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            return itemScript.ItemType();
        }
    }
    public int inventoryPosition
    {
        get
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            return itemScript.inventoryPosition;
        }
    }

    public void OnBeginDrag(PointerEventData eventData)
    {
        this.transform.parent = canvas;
        this.transform.SetAsLastSibling();
        Image itemImage = GetComponent<Image>();
        itemImage.raycastTarget = false;
    }

    public void OnDrag(PointerEventData eventData)
    {
        this.transform.position = eventData.position;
    }

    public void OnEndDrag(PointerEventData eventData)
    {
        this.transform.parent = currentParent;
        this.transform.localPosition = new Vector3(0, 0, 0);
        Image itemImage = GetComponent<Image>();
        itemImage.raycastTarget = true;
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (item != null)
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            string itemName = itemScript.ItemName();
            string itemDescription = itemScript.ItemDescription();
            RectTransform itemSlotRectTransform = currentParent.GetComponent<RectTransform>();
            Vector3[] itemCorners = new Vector3[4];
            itemSlotRectTransform.GetWorldCorners(itemCorners);
            Vector3 itemBottomRightPosition = itemCorners[3];

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
                tooltipRectTransform.position = itemBottomRightPosition;
                TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
                StartCoroutine(tooltipScript.SetText(itemName, itemDescription));
                tooltip.SetActive(true);
            }
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnPointerClick(PointerEventData eventData)
    {
        if (item == null) return;
        if (eventData.button == PointerEventData.InputButton.Right)
        {
            if (contextMenu != null)
            {

            }
            RectTransform itemSlotRectTransform = currentParent.GetComponent<RectTransform>();
            Vector3[] itemCorners = new Vector3[4];
            itemSlotRectTransform.GetWorldCorners(itemCorners);
            Vector3 itemBottomLeftPosition = itemCorners[0];
            Transform contextMenuTransform = canvas.Find("Context Menu");
            if (contextMenuTransform != null)
            {
                contextMenu = contextMenuTransform.gameObject;
                DestroyImmediate(contextMenu);
            }
            if (contextMenu == null)
            {
                contextMenu = Instantiate(contextMenuPrefab, canvas);
                contextMenu.name = "Context Menu";
                contextMenu.transform.SetAsLastSibling();
            }
            if (contextMenu != null)
            {
                RectTransform contextMenuRectTransform = contextMenu.GetComponent<RectTransform>();
                contextMenuRectTransform.pivot = new Vector2(0, 1f);
                contextMenuRectTransform.position = itemBottomLeftPosition;
                ContextMenuScript contextMenuScript = contextMenu.GetComponent<ContextMenuScript>();
                StartCoroutine(contextMenuScript.BuildButtons(this.gameObject));
                contextMenu.SetActive(true);
            }
        }
    }

    void Start()
    {
        currentParent = this.transform.parent;
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
        contextMenuPrefab = Resources.Load<GameObject>("Prefabs/Context Menu");
    }

    void OnDestroy()
    {

        if (tooltip != null)
        {
            Destroy(tooltip);
        }
        if (contextMenu != null)
        {
            Destroy(contextMenu);
        }
    }
}
