using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class InventoryItemScript : MonoBehaviour, IBeginDragHandler, IDragHandler, IEndDragHandler
{
    public GameObject item;
    public Transform currentParent;
    public Transform canvas;
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

    void Start()
    {
        currentParent = this.transform.parent;
        canvas = GameObject.Find("Canvas").transform;
    }
}
