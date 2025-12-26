using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;
using System.Collections.Generic;

public class CanvasScript : MonoBehaviour
{
    void Update()
    {
        Mouse mouse = Mouse.current;
        if (mouse != null)
        {
            if (mouse.leftButton.wasPressedThisFrame || mouse.rightButton.wasPressedThisFrame)
            {
                // check if clicking on an inventory item
                PointerEventData pointerData = new PointerEventData(EventSystem.current);
                pointerData.position = mouse.position.ReadValue();
                List<RaycastResult> results = new List<RaycastResult>();
                EventSystem.current.RaycastAll(pointerData, results);

                bool clickedOnInventoryItem = false;
                bool clickedOnContextMenu = false;
                Transform contextMenuTransform = this.transform.Find("Context Menu");

                foreach (RaycastResult result in results)
                {
                    if (result.gameObject.GetComponent<InventoryItemScript>() != null)
                    {
                        clickedOnInventoryItem = true;
                        break;
                    }
                    if (contextMenuTransform != null && result.gameObject.transform.IsChildOf(contextMenuTransform))
                    {
                        clickedOnContextMenu = true;
                        break;
                    }
                }

                // only destroy if not clicking on an inventory item or context menu
                if (!clickedOnInventoryItem && !clickedOnContextMenu)
                {
                    if (contextMenuTransform != null)
                    {
                        DestroyImmediate(contextMenuTransform.gameObject);
                    }
                }
            }
        }
    }
}
