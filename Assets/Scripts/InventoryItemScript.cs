using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class InventoryItemScript : MonoBehaviour, IBeginDragHandler, IDragHandler, IEndDragHandler, IPointerEnterHandler, IPointerExitHandler
{
    public GameObject item;
    public Transform currentParent;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public string itemType
    {
        get
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            return itemScript.ItemType();
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
            Vector3 itemTopRightPosition = itemCorners[2];

            if (tooltip == null)
            {
                tooltip = Instantiate(tooltipPrefab, canvas);
                tooltip.transform.SetAsLastSibling();
                RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
                tooltipRectTransform.pivot = new Vector2(0, 1f);
                tooltipRectTransform.position = itemTopRightPosition;
                TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
                StartCoroutine(tooltipScript.SetText(itemName, itemDescription));
            }
            if (tooltip != null)
            {
                RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
                tooltipRectTransform.pivot = new Vector2(0, 1f);
                tooltipRectTransform.position = itemTopRightPosition;
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

    void Start()
    {
        currentParent = this.transform.parent;
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
    }

    void OnDestroy()
    {
        if (tooltip != null)
        {
            Destroy(tooltip);
        }
    }
}
